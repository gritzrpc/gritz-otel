# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"
require "opentelemetry-metrics-sdk"
require "opentelemetry-exporter-otlp-metrics"

RSpec.describe "OpenTelemetry worker bootstrap" do
  let(:config) { Gritz::Configuration.new }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    @previous_middleware = Gritz::Client.middleware
    @previous_disabled = ENV.fetch("OTEL_SDK_DISABLED", nil)
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
    ENV.delete("OTEL_SDK_DISABLED")
  end
  after do
    Gritz::Otel.shutdown(timeout: 0.1)
    Gritz::Client.middleware = @previous_middleware
    @previous_disabled ? ENV["OTEL_SDK_DISABLED"] = @previous_disabled : ENV.delete("OTEL_SDK_DISABLED")
  end

  it "surfaces a user's invalid SDK configuration as a failed worker boot" do
    failure = RuntimeError.new("invalid SDK configuration")
    Gritz::Otel.install(config) { raise failure }
    expect { config.run_hooks(:on_worker_boot, 0) }.to(raise_error { |error| expect(error).to equal(failure) })
    expect(Gritz::Otel.instance_variable_get(:@pid)).not_to eq(Process.pid)
  end

  it "surfaces a provider configuration failure instead of continuing with partially configured telemetry" do
    failure = RuntimeError.new("provider initialization failed")
    allow_any_instance_of(OpenTelemetry::SDK::Configurator).to receive(:configure).and_raise(failure)
    Gritz::Otel.install(config)
    expect { config.run_hooks(:on_worker_boot, 0) }.to(raise_error { |error| expect(error).to equal(failure) })
  end

  it "honors SDK_DISABLED without allocating exporters, spans, or running the configurator" do
    ENV["OTEL_SDK_DISABLED"] = "true"
    config.metrics_backend = :otlp
    expect(OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter).not_to receive(:new)
    expect(OpenTelemetry::SDK::Configurator).not_to receive(:new)
    configured = false
    Gritz::Otel.install(config) { configured = true }
    config.run_hooks(:on_worker_boot, 0)
    expect(configured).to be false
    recorder = config.metrics_recorder_factory.call(worker: 0)
    recorder.record_rpc(service: "test.Service", method: "Call", code: 0, duration: 0.01, requests: 1, responses: 1)
    expect(recorder.take_delta[:rpc].first[:count]).to eq(1)
    invocation = Gritz::Client::Invocation.new
    expect(OpenTelemetry.tracer_provider).not_to receive(:tracer)
    expect(invocation.call(->(_ctx) { :reply }, method: "/test.Service/Call", kind: :unary, request: nil, options: invocation.options)).to eq(:reply)
  end

  it "owns and shuts down the trace-only metrics provider after the metrics SDK has been loaded" do
    Gritz::Otel.install(config) do |sdk|
      sdk.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    end
    config.run_hooks(:on_worker_boot, 0)
    provider = OpenTelemetry.meter_provider
    expect(provider.metric_readers.map(&:class)).to eq([OpenTelemetry::SDK::Metrics::Export::MetricReader])
    expect(provider).to receive(:shutdown).with(timeout: a_value_between(0, 0.1)).and_call_original
    Gritz::Otel.shutdown(timeout: 0.1)
    expect(provider.meter("after-close")).to be_an_instance_of(OpenTelemetry::Metrics::Meter)
  end

  it "uses RPC-scale histogram boundaries for durations and streamed message counts" do
    config.metrics_backend = :otlp
    Gritz::Otel.install(config) do |sdk|
      sdk.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    end
    config.run_hooks(:on_worker_boot, 0)
    reader = OpenTelemetry.meter_provider.metric_readers.first
    allow(reader).to receive(:export)
    recorder = config.metrics_recorder_factory.call(worker: 0)
    recorder.record_rpc(service: "test.Service", method: "Call", code: 0, duration: 0.004, requests: 1, responses: 0)
    recorder.record_rpc(service: "test.Service", method: "Call", code: 0, duration: 0.2, requests: 128, responses: 7)
    histograms = reader.collect.to_h { |metric| [metric.name, metric.data_points.first] }
    duration = histograms.fetch("gritz.rpc.server.duration")
    expect(duration.explicit_bounds).to eq(Gritz::Metrics::Recorder::DURATION_BUCKETS.select(&:finite?))
    expect(duration.bucket_counts.first).to eq(1)
    expect(duration.bucket_counts[duration.explicit_bounds.index(0.25)]).to eq(1)
    %w[requests responses].each do |name|
      expect(histograms.fetch("gritz.rpc.server.#{name}").explicit_bounds).to eq(Gritz::Metrics::Recorder::MESSAGE_BUCKETS.select(&:finite?))
    end
  end
end
