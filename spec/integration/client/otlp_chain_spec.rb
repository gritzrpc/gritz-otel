# frozen_string_literal: true

require "spec_helper"
require "gritz/native"
require "json"
require "tmpdir"
require_relative "support/otlp_collector"
$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Forked native client OTLP chain", skip: RUBY_PLATFORM.include?("linux") ? false : "forked OTLP E2E requires Linux" do
  around do |example|
    Dir.mktmpdir("gritz-otlp-chain") do |directory|
      @events_path = File.join(directory, "events.jsonl")
      @clusters = {}
      @addresses = {}
      @collector = OtlpCollector.new
      example.run
    ensure
      @clusters.values.reverse_each do |cluster|
        owned = [cluster.pid, cluster.master_pid, *cluster.workers.map { |worker| worker[:pid] }].compact.uniq
        cluster.stop(timeout: 3)
        expect(cluster.wait).to be_success if @chain_ready
        owned.each { |pid| expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) }
      end
      expect(@collector.errors).to be_empty
      @collector.close
    end
  end

  def free_address
    listener = TCPServer.new("127.0.0.1", 0)
    "127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
  end

  def start_chain
    @chain_ready = false
    %w[c b a].each do |role|
      @addresses[role] = free_address
      env = { "CLIENT_E2E_ROLE" => role, "CLIENT_E2E_EVENTS" => @events_path,
              "CLIENT_E2E_BIND" => @addresses.fetch(role), "CLIENT_E2E_ADMIN" => free_address,
              "CLIENT_E2E_WORKERS" => role == "a" ? "2" : "1", "CLIENT_E2E_OTEL" => "true",
              "OTEL_EXPORTER_OTLP_ENDPOINT" => @collector.endpoint, "OTEL_BSP_SCHEDULE_DELAY" => "50" }
      if role != "c"
        env["CLIENT_E2E_TARGET"] = @addresses.fetch(role == "a" ? "b" : "c")
        env["CLIENT_E2E_DEADLINE"] = role == "a" ? "1" : "0.75"
      end
      @clusters[role] = Gritz::Testing::Cluster.new(config_path: File.expand_path("fixtures/config.rb", __dir__), env:)
      @clusters.fetch(role).start.wait_until(workers: Integer(env.fetch("CLIENT_E2E_WORKERS")))
    end
    @chain_ready = true
  end

  def rpc(metadata: {})
    address = @addresses.fetch("a")
    channel = GRPC::Core::Channel.new(address, { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }, :this_channel_is_insecure)
    stub = Helloworld::Greeter::Stub.new(address, :this_channel_is_insecure, channel_override: channel)
    JSON.parse(stub.say_hello(Helloworld::HelloRequest.new(name: "ok"), deadline: Time.now + 2, metadata:).message)
  ensure
    channel&.close
  end

  def events = File.readlines(@events_path).map { |line| JSON.parse(line) }

  it "exports one trace joining all three server and both client spans over HTTP" do
    start_chain
    incoming = "00-11111111111111111111111111111111-2222222222222222-01"
    hops = rpc(metadata: { "traceparent" => incoming, "x-request-id" => "otel-chain" }).fetch("hops")
    @collector.wait_until { @collector.spans.size == 5 }
    spans = @collector.spans
    expect(spans.map { |entry| entry[:span].trace_id.unpack1("H*") }.uniq).to eq(["1" * 32])
    server = {}
    client = {}
    spans.each do |entry|
      role = entry[:resource].fetch("service.name").delete_prefix("client-e2e-")
      span = entry[:span]
      expect(entry[:resource].fetch("process.pid")).to eq(hops.find { |hop| hop["role"] == role }.fetch("pid"))
      expect(entry[:resource].fetch("service.instance.id")).to eq(entry[:resource].fetch("process.pid").to_s)
      expect(OtlpCollector.attributes(span.attributes)).to include("rpc.system" => "grpc", "rpc.service" => "helloworld.Greeter",
                                                                   "rpc.method" => "SayHello", "rpc.grpc.status_code" => 0)
      (span.kind == :SPAN_KIND_SERVER ? server : client)[role] = span
    end
    expect(server.keys.sort).to eq(%w[a b c])
    expect(client.keys.sort).to eq(%w[a b])
    expect(server.fetch("a").parent_span_id.unpack1("H*")).to eq("2" * 16)
    expect(client.fetch("a").parent_span_id).to eq(server.fetch("a").span_id)
    expect(server.fetch("b").parent_span_id).to eq(client.fetch("a").span_id)
    expect(client.fetch("b").parent_span_id).to eq(server.fetch("b").span_id)
    expect(server.fetch("c").parent_span_id).to eq(client.fetch("b").span_id)
    expect(hops.map { |hop| hop["request_id"] }).to eq(["otel-chain"] * 3)
    expect(hops.map { |hop| hop["traceparent"].split("-")[1] }).to eq(["1" * 32] * 3)
    expect(hops[1].fetch("traceparent").split("-")[2]).to eq(client.fetch("a").span_id.unpack1("H*"))
    expect(hops[2].fetch("traceparent").split("-")[2]).to eq(client.fetch("b").span_id.unpack1("H*"))
    expect(@collector.requests.select { |request| request[:path] == "/v1/traces" }.map { |request| request[:headers]["content-encoding"] }.uniq).to eq(["gzip"])
  end

  it "registers safely in each parent and initializes the SDK in every worker" do
    start_chain
    registrations = events.select { |event| event["event"] == "otel_registered" }
    worker_pids = @clusters.values.flat_map { |cluster| cluster.workers.map { |worker| worker[:pid] } }.sort
    boots = events.select { |event| event["event"] == "sdk_booted" }
    expect(boots.map { |event| event["pid"] }.sort).to eq(worker_pids)
    boots.each { |event| expect(event).to include("sdk_loaded" => true, "sdk_threads" => 1) }
    expect(registrations.map { |event| event["pid"] } & worker_pids).to be_empty
    @clusters.each_value do |cluster|
      expect(registrations).to include(include("pid" => cluster.master_pid, "sdk_loaded" => false, "sdk_threads" => 0))
    end
    expect(events.select { |event| event["event"] == "channel" }).to be_empty
  end

  it "exports exact completed RPC counts and memory gauges from every worker over HTTP" do
    start_chain
    expected = Hash.new(0)
    worker_pids = @clusters.values.flat_map { |cluster| cluster.workers.map { |worker| worker[:pid] } }
    @collector.wait_until do
      4.times { rpc.fetch("hops").each { |hop| expected[hop.fetch("pid")] += 1 } }
      (worker_pids - expected.keys).empty?
    end
    totals = nil
    @collector.wait_until do
      totals = duration_counts
      expected.all? { |pid, count| totals[pid] == count }
    end
    expect(totals).to eq(expected)
    expect(totals.values.sum).to eq(events.count { |event| event["event"] == "request" })
    gauges = @collector.metrics.select { |entry| entry[:metric].name == "gritz.worker.rss_bytes" }
    expect(gauges.map { |entry| entry[:resource].fetch("process.pid") }.uniq.sort).to eq(worker_pids.sort)
    expect(gauges).to all(satisfy { |entry| entry[:metric].gauge.data_points.first.as_int.positive? })
    expect(@collector.requests.select { |request|
      request[:path] == "/v1/metrics"
    }.map { |request| request[:headers]["content-encoding"] }.uniq).to eq(["gzip"])
  end

  def duration_counts
    @collector.metrics.each_with_object({}) do |entry, counts|
      next unless entry[:metric].name == "gritz.rpc.server.duration"

      histogram = entry[:metric].histogram
      expect(histogram.aggregation_temporality).to eq(:AGGREGATION_TEMPORALITY_CUMULATIVE)
      pid = entry[:resource].fetch("process.pid")
      counts[pid] = histogram.data_points.sum do |point|
        expect(OtlpCollector.attributes(point.attributes)).to include("process.pid" => pid, "rpc.grpc.status_code" => 0)
        point.count
      end
    end
  end
end
