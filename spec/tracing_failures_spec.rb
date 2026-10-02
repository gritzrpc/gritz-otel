# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe "OpenTelemetry tracing failure isolation" do
  let(:config) { Gritz::Configuration.new }
  let(:processor_class) do
    Class.new do
      attr_accessor :fail_on

      def on_start(_span, _parent)
        raise "private SDK start failure" if fail_on == :start
      end

      def on_finish(_span)
        raise "private SDK finish failure" if fail_on == :finish
      end

      def shutdown(**) = 0
      def force_flush(**) = 0
    end
  end
  let(:processor) { processor_class.new }

  before do
    @previous_middleware = Gritz::Client.middleware
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
    Gritz::Otel.install(config) { |sdk| sdk.add_span_processor(processor) }
    config.run_hooks(:on_worker_boot, 0)
    allow(OpenTelemetry.logger).to receive(:warn)
  end
  after do
    Gritz::Otel.shutdown(timeout: 0.1)
    Gritz::Client.middleware = @previous_middleware
  end

  def invoke(&terminal)
    invocation = Gritz::Client::Invocation.new
    invocation.call(terminal, method: "/test.Service/Call", kind: :unary, request: nil, options: invocation.options)
  end

  it "runs the RPC exactly once with an invalid span when a processor fails to start" do
    processor.fail_on = :start
    calls = 0
    original = OpenTelemetry::Context.current
    expect(invoke do |_context|
      calls += 1
      expect(OpenTelemetry::Trace.current_span).to equal(OpenTelemetry::Trace::Span::INVALID)
      :reply
    end).to eq(:reply)
    expect(calls).to eq(1)
    expect(OpenTelemetry::Context.current).to equal(original)
    expect(OpenTelemetry.logger).to have_received(:warn).with("Gritz tracing failed to start (RuntimeError)")
  end

  it "preserves successful RPC completion when a processor fails to finish" do
    processor.fail_on = :finish
    calls = 0
    expect(invoke do |_context|
      calls += 1
      :reply
    end).to eq(:reply)
    expect(calls).to eq(1)
    expect(OpenTelemetry.logger).to have_received(:warn).with("Gritz tracing failed to finish (RuntimeError)")
  end

  it "preserves the original application error when a processor also fails to finish" do
    processor.fail_on = :finish
    failure = Gritz::Errors::NotFound.new("application missing")
    calls = 0
    expect {
      invoke do |_context|
        calls += 1
        raise failure
      end
    }.to raise_error(Gritz::Errors::NotFound) { |error| expect(error).to equal(failure) }
    expect(calls).to eq(1)
    expect(OpenTelemetry.logger).to have_received(:warn).with("Gritz tracing failed to finish (RuntimeError)")
  end
end
