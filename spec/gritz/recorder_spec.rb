# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry-metrics-sdk"
require "opentelemetry-exporter-otlp-metrics"

RSpec.describe Gritz::Otel::Recorder do
  before do
    @previous_middleware = Gritz::Client.middleware
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
    @config = Gritz::Configuration.new
    @config.metrics_backend = :otlp
    @config.status_interval = 0.04
    @config.shutdown_timeout = 0.4
    @trace_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    Gritz::Otel.install(@config) do |sdk|
      sdk.service_name = "recorder-spec"
      sdk.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@trace_exporter))
    end
    @config.run_hooks(:on_worker_boot, 2)
    @meter_provider = OpenTelemetry.meter_provider
    @exporter = @meter_provider.metric_readers.find { |reader| reader.is_a?(OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter) }
    @exports = []
    allow(@exporter).to receive(:export) do |metrics, timeout:|
      @exports << { metrics:, timeout: }
      OpenTelemetry::SDK::Metrics::Export::SUCCESS
    end
    @recorder = @config.metrics_recorder_factory.call(worker: 2)
  end

  after do
    Gritz::Otel.shutdown(timeout: 0.1)
    Gritz::Client.middleware = @previous_middleware
  end

  def observe(**status)
    @recorder.observe_worker({ state: "ready", inflight: 3, busy_threads: 4, capacity: 8 }.merge(status))
    @exports.last.fetch(:metrics)
  end

  def metric(snapshot, name)
    snapshot.find { |entry| entry.name == name } || raise("missing metric #{name}")
  end

  def point(snapshot, name) = metric(snapshot, name).data_points.fetch(0)

  it "collects real RPC histograms and monotonic rejection totals without consuming pipe deltas" do
    @recorder.record_rpc(service: "test.Greeter", method: "Hello", code: 0, duration: 0.01, requests: 2, responses: 1)
    @recorder.record_rpc(service: "test.Greeter", method: "Hello", code: 0, duration: 0.02, requests: 3, responses: 4)
    [3, 3, 5].each { |total| @recorder.observe_rejected(total) }
    expect { @recorder.observe_rejected(4) }.to raise_error(ArgumentError, /nondecreasing/)
    snapshot = observe
    expect(snapshot).to all(be_a(OpenTelemetry::SDK::Metrics::State::MetricData))
    { "duration" => [0.03, "s"], "requests" => [5, "{message}"], "responses" => [5, "{message}"] }.each do |name, (sum, unit)|
      data = metric(snapshot, "gritz.rpc.server.#{name}")
      histogram = data.data_points.fetch(0)
      expect(data.instrument_kind).to eq(:histogram)
      expect(data.unit).to eq(unit)
      expect(histogram.count).to eq(2)
      expect(histogram.sum).to be_within(0.000001).of(sum)
      expect(histogram.bucket_counts.sum).to eq(2)
      expect(histogram.attributes).to include("worker.index" => 2, "process.pid" => Process.pid,
                                              "rpc.system" => "grpc", "rpc.service" => "test.Greeter", "rpc.method" => "Hello", "rpc.grpc.status_code" => 0)
      expect(data.resource.attribute_enumerator.to_h).to include("service.name" => "recorder-spec", "process.pid" => Process.pid)
    end
    counter = metric(snapshot, "gritz.rpc.server.rejected")
    expect(counter.is_monotonic).to be(true)
    expect(counter.data_points.fetch(0).value).to eq(5)
    delta = @recorder.take_delta
    expect(delta[:rpc].first).to include(count: 2, duration_sum: 0.03, request_sum: 5, response_sum: 5)
    expect(delta[:rejected]).to eq(5)
    expect(@recorder.take_delta).to be_nil

    @recorder.observe_rejected(7)
    expect(point(observe, "gritz.rpc.server.rejected").value).to eq(7)
    expect(@recorder.take_delta).to eq(rpc: [], rejected: 2)
  end

  it "collects worker occupancy, capacity, lifecycle and actual Linux RSS/PSS gauges" do
    snapshot = observe
    { "inflight" => 3, "busy_threads" => 4, "capacity" => 8 }.each do |name, value|
      expect(point(snapshot, "gritz.worker.#{name}").value).to eq(value)
      expect(point(snapshot, "gritz.worker.#{name}").attributes).to eq("worker.index" => 2, "process.pid" => Process.pid)
    end
    states = metric(snapshot, "gritz.worker.state").data_points.to_h { |entry| [entry.attributes.fetch("state"), entry.value] }
    expect(states).to eq("booting" => 0, "ready" => 1, "draining" => 0, "failed" => 0, "stopped" => 0)
    states = metric(observe(state: "draining", inflight: 1, busy_threads: 1), "gritz.worker.state").data_points
    expect(states.to_h { |entry| [entry.attributes.fetch("state"), entry.value] }).to include("ready" => 0, "draining" => 1)
    if RUBY_PLATFORM.include?("linux")
      rss = point(snapshot, "gritz.worker.rss_bytes").value
      pss = point(snapshot, "gritz.worker.pss_bytes").value
      expect(pss).to be_positive
      expect(rss).to be >= pss
      expect(pss % 1024).to eq(0)
    end
  end

  it "bounds heartbeat exports and shuts down the official trace and metrics providers on close" do
    allow(@exporter).to receive(:export) do |metrics, timeout:|
      @exports << { metrics:, timeout: }
      sleep timeout
      OpenTelemetry::SDK::Metrics::Export::SUCCESS
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    observe
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(@exports.last[:timeout]).to be > 0
    expect(@exports.last[:timeout]).to be <= @config.status_interval / 2.0
    expect(@exports.last[:timeout]).to be <= @config.shutdown_timeout / 4.0
    expect(elapsed).to be < 0.2
    allow(@exporter).to receive(:export) do |metrics, timeout:|
      @exports << { metrics:, timeout: }
      OpenTelemetry::SDK::Metrics::Export::SUCCESS
    end
    @recorder.record_rpc(service: "test.Greeter", method: "Final", code: 14, duration: 0.01, requests: 1, responses: 0)
    expect(OpenTelemetry.tracer_provider).to receive(:shutdown).with(timeout: a_value_between(0, 0.1)).and_call_original
    expect(@meter_provider).to receive(:shutdown).with(timeout: a_value_between(0, 0.1)).and_call_original
    expect(@exporter).to receive(:shutdown).with(timeout: a_value_between(0, 0.1)).and_call_original
    @recorder.close(timeout: 0.1)
    expect(point(@exports.last[:metrics], "gritz.rpc.server.duration").count).to eq(1)
    expect(point(@exports.last[:metrics], "gritz.rpc.server.duration").attributes).to include("rpc.method" => "Final", "rpc.grpc.status_code" => 14)
    expect(@meter_provider.meter("after-close")).to be_an_instance_of(OpenTelemetry::Metrics::Meter)
  end
end
