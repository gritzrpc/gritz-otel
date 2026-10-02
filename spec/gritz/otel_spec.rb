# frozen_string_literal: true

require "opentelemetry/sdk"
require "gritz/core"
require "logger"

RSpec.describe Gritz::Otel do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:config) { Gritz::Configuration.new }

  def install
    described_class.install(config) do |sdk|
      sdk.service_name = "otel-spec"
      sdk.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    end
  end

  def context(metadata: {})
    descriptor = Gritz::MethodDescriptor.new(service: "test.Greeter", name: "Hello", input_type: nil, output_type: nil)
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: descriptor, messages: [], metadata:)
    Gritz::Context.new(call:, logger: Logger.new(File::NULL))
  end

  after do
    described_class.shutdown(timeout: 1) if described_class.respond_to?(:shutdown)
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
  end

  it "installs idempotently without configuring the SDK in the master" do
    configured = 0
    2.times { described_class.install(config) { configured += 1 } }
    expect(configured).to eq(0)
    expect(config.middleware.entries.count { |entry| entry.middleware == Gritz::Otel::ServerTracing }).to eq(1)
    expect(Gritz::Client.middleware.entries.count { |entry| entry.middleware == Gritz::Otel::ClientTracing }).to eq(1)
    config.run_hooks(:on_worker_boot, 0)
    config.run_hooks(:on_worker_boot, 0)
    expect(configured).to eq(1)
  end

  it "registers the integration through a configuration-file DSL without starting the SDK" do
    configured = false
    Gritz::DSL.new(config).instance_eval { opentelemetry { configured = true } }
    expect(configured).to be(false)
    expect(config.metrics_recorder_factory).to respond_to(:call)
    config.run_hooks(:on_worker_boot, 0)
    expect(configured).to be(true)
  end

  it "closes both providers even when the final metric exporter raises" do
    install
    config.run_hooks(:on_worker_boot, 0)
    provider = OpenTelemetry.tracer_provider
    metric_provider = double("meter provider", shutdown: nil)
    metrics = double("metric reader", collect: [])
    allow(metrics).to receive(:export).and_raise("secret collector response")
    allow(OpenTelemetry.logger).to receive(:warn)
    described_class.instance_variable_set(:@metrics_exporter, metrics)
    described_class.instance_variable_set(:@meter_provider, metric_provider)
    expect(provider).to receive(:shutdown).with(timeout: kind_of(Numeric)).and_call_original
    expect(metric_provider).to receive(:shutdown).with(timeout: kind_of(Numeric))
    expect { described_class.shutdown(timeout: 1) }.not_to raise_error
    expect(OpenTelemetry.logger).to have_received(:warn).with("Gritz telemetry shutdown failed (RuntimeError)")
  end

  it "connects incoming server and outgoing client spans and restores the ambient context" do
    install
    config.run_hooks(:on_worker_boot, 0)
    carrier = { "traceparent" => "00-11111111111111111111111111111111-2222222222222222-01" }
    ctx = context(metadata: carrier)
    before = OpenTelemetry::Context.current
    received = nil
    terminal = lambda do |client|
      received = client.metadata.dup
      expect(OpenTelemetry::Trace.current_span.context.trace_id.unpack1("H*")).to eq("1" * 32)
      :response
    end
    app = Gritz::Otel::ServerTracing.new(lambda do |server|
      Gritz::Context.with(server) do
        invocation = Gritz::Client::Invocation.new(parent: server)
        invocation.call(terminal, method: "/test.Downstream/Hello", kind: :unary, request: nil, options: invocation.options)
      end
    end)
    expect(app.call(ctx)).to eq(:response)
    expect(OpenTelemetry::Context.current).to equal(before)
    spans = exporter.finished_spans
    server = spans.find { |span| span.kind == :server }
    client = spans.find { |span| span.kind == :client }
    expect(server.parent_span_id.unpack1("H*")).to eq("2" * 16)
    expect(client.parent_span_id).to eq(server.span_id)
    expect(received["traceparent"]).to include(client.span_id.unpack1("H*"))
    expect(spans.map { |span| span.attributes["rpc.grpc.status_code"] }).to eq([0, 0])
    expect(server.resource.attribute_enumerator.to_h["process.pid"]).to eq(Process.pid)
  end

  it "keeps a lazy streaming client span open until enumeration exits" do
    install
    config.run_hooks(:on_worker_boot, 0)
    tracer = OpenTelemetry.tracer_provider.tracer("caller")
    stream = tracer.in_span("parent") do
      invocation = Gritz::Client::Invocation.new
      terminal = ->(_ctx, &reply) { 3.times { |i| reply.call(i) } }
      invocation.call(terminal, method: "/test.Downstream/Watch", kind: :server_streaming, request: nil, options: invocation.options)
    end
    parent = exporter.finished_spans.first
    expect(exporter.finished_spans.size).to eq(1)
    expect(stream.first).to eq(0)
    client = exporter.finished_spans.find { |span| span.kind == :client }
    expect(client.parent_span_id).to eq(parent.span_id)
    expect(OpenTelemetry::Trace.current_span.context.valid?).to be(false)
  end

  it "records the final RPC code without exception messages or payloads" do
    install
    config.run_hooks(:on_worker_boot, 0)
    app = Gritz::Otel::ServerTracing.new(->(_ctx) { raise Gritz::Errors::NotFound, "secret payload" })
    expect { app.call(context) }.to raise_error(Gritz::Errors::NotFound)
    span = exporter.finished_spans.last
    expect(span.attributes["rpc.grpc.status_code"]).to eq(5)
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(Array(span.events)).to be_empty
    expect(span.status.description).not_to include("secret")
  end

  it "propagates only W3C trace headers and removes stale child trace fields" do
    install
    config.run_hooks(:on_worker_boot, 0)
    carrier = { "traceparent" => "00-11111111111111111111111111111111-2222222222222222-01", "baggage" => "private=secret" }
    ctx = context(metadata: carrier)
    received = nil
    app = Gritz::Otel::ServerTracing.new(lambda do |server|
      Gritz::Context.with(server) do
        invocation = Gritz::Client::Invocation.new(parent: server, options: { metadata: { "tracestate" => "stale=value" } })
        terminal = ->(client) { received = client.metadata.dup }
        invocation.call(terminal, method: "/test.Downstream/Hello", kind: :unary, request: nil, options: invocation.options)
      end
    end)
    app.call(ctx)
    expect(received.keys).to contain_exactly("x-request-id", "traceparent")
    expect(received["traceparent"]).to start_with("00-#{'1' * 32}-")
  end

  it "accepts native duplicate metadata without making malformed trace headers fail the RPC" do
    install
    config.run_hooks(:on_worker_boot, 0)
    traceparent = "00-11111111111111111111111111111111-2222222222222222-01"
    app = Gritz::Otel::ServerTracing.new(->(_ctx) { :reply })
    expect(app.call(context(metadata: { "traceparent" => [traceparent, traceparent] }))).to eq(:reply)
    expect(exporter.finished_spans.last.parent_span_id).to eq(OpenTelemetry::Trace::SpanContext::INVALID.span_id)
    expect(app.call(context(metadata: { "traceparent" => traceparent, "tracestate" => ["one=1", "two=2"] }))).to eq(:reply)
    expect(exporter.finished_spans.last.tracestate.to_s).to eq("one=1,two=2")
  end

  it "records CANCELLED when a lazy client stream exits early while preserving explicit error codes" do
    install
    config.run_hooks(:on_worker_boot, 0)
    invocation = Gritz::Client::Invocation.new
    terminal = lambda do |ctx, &reply|
      reply.call(:first)
      reply.call(:second)
    ensure
      ctx.store[:gritz_cancelled] = true
    end
    stream = invocation.call(terminal, method: "/test.Downstream/Watch", kind: :server_streaming, request: nil, options: invocation.options)
    expect(stream.first).to eq(:first)
    expect(exporter.finished_spans.last.attributes["rpc.grpc.status_code"]).to eq(1)
    expect(exporter.finished_spans.last.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)

    invocation = Gritz::Client::Invocation.new
    terminal = lambda do |ctx|
      raise Gritz::Errors::NotFound, "missing"
    ensure
      ctx.store[:gritz_cancelled] = true
    end
    expect { invocation.call(terminal, method: "/test.Downstream/Hello", kind: :unary, request: nil, options: invocation.options) }
      .to raise_error(Gritz::Errors::NotFound)
    expect(exporter.finished_spans.last.attributes["rpc.grpc.status_code"]).to eq(5)
  end
end
