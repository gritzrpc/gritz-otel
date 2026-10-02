# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"
require "opentelemetry-metrics-sdk"

RSpec.describe Gritz::Otel::Recorder do
  let(:reader_class) do
    Class.new(OpenTelemetry::SDK::Metrics::Export::MetricReader) do
      attr_reader :exports

      def initialize
        super
        @exports = []
      end

      def export(metrics, timeout:)
        @exports << [metrics, timeout]
      end
    end
  end
  let(:reader) { reader_class.new }
  let(:recorder) { described_class.new(worker: 2, exporter: reader, timeout: 0.1) }
  let(:observation) { { service: "test.Service", method: "Call", code: 0, duration: 0.01, requests: 1, responses: 2 } }
  let(:status) { { inflight: 1, busy_threads: 2, capacity: 4, state: "ready" } }

  before do
    @previous_provider = OpenTelemetry.meter_provider
    @previous_logger = OpenTelemetry.logger
    OpenTelemetry.logger = Logger.new(File::NULL)
    @provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    @provider.add_metric_reader(reader)
    OpenTelemetry.meter_provider = @provider
  end
  after do
    @provider.shutdown(timeout: 0)
    OpenTelemetry.meter_provider = @previous_provider
    OpenTelemetry.logger = @previous_logger
  end

  it "keeps reliable pipe deltas when an SDK instrument raises" do
    allow(recorder.instance_variable_get(:@duration)).to receive(:record).and_raise("SDK instrument failed")
    expect { recorder.record_rpc(**observation) }.not_to raise_error
    row = recorder.take_delta[:rpc].first
    expect(row).to include(count: 1, duration_sum: 0.01, request_sum: 1, response_sum: 2)
  end

  it "preserves base validation errors before isolating telemetry failures" do
    expect { recorder.record_rpc(**observation, duration: -1) }.to raise_error(ArgumentError, /metric observation/)
    expect(recorder.take_delta).to be_nil
  end

  it "keeps rejected deltas when an SDK counter raises" do
    allow(recorder.instance_variable_get(:@rejections)).to receive(:add).and_raise("SDK counter failed")
    expect { recorder.observe_rejected(3) }.not_to raise_error
    expect(recorder.take_delta[:rejected]).to eq(3)
    expect { recorder.observe_rejected(2) }.to raise_error(ArgumentError, /nondecreasing/)
  end

  it "isolates a failed SDK collect or export from worker heartbeat observations" do
    allow(reader).to receive(:collect).and_raise("SDK reader failed")
    expect { recorder.observe_worker(status) }.not_to raise_error
    allow(reader).to receive(:collect).and_call_original
    allow(reader).to receive(:export).and_raise("collector failed")
    expect { recorder.observe_worker(status) }.not_to raise_error
  end

  it "records final stopped gauges without adding another HTTP request after grace" do
    recorder.observe_worker(status)
    expect(reader.exports.size).to eq(1)
    recorder.observe_worker(status.merge(state: "stopped", inflight: 0, busy_threads: 0))
    expect(reader.exports.size).to eq(1)
    metric = reader.collect.find { |row| row.name == "gritz.worker.state" }
    expect(metric.data_points.find { |point| point.attributes["state"] == "stopped" }.value).to eq(1)
  end
end
