# frozen_string_literal: true

require_relative "application"

workers Integer(ENV.fetch("CLIENT_E2E_WORKERS", "1"))
bind ENV.fetch("CLIENT_E2E_BIND")
admin_bind ENV.fetch("CLIENT_E2E_ADMIN")
status_interval 0.1
worker_timeout 2.0
worker_boot_timeout 5.0
drain_delay 0.02
shutdown_timeout 1.0
preload_app!
register_controller ClientChain::Controller

if ENV["CLIENT_E2E_OTEL"] == "true"
  require "gritz/otel"
  metrics_backend :otlp
  opentelemetry { |sdk| sdk.service_name = "client-e2e-#{ClientChain::ROLE}" }
  ClientChain.record("otel_registered", sdk_loaded: !defined?(OpenTelemetry::SDK).nil?, sdk_threads: ClientChain.sdk_threads)
  on_worker_boot do |_worker|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.001 while ClientChain.sdk_threads.zero? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    ClientChain.record("sdk_booted", sdk_loaded: !defined?(OpenTelemetry::SDK).nil?, sdk_threads: ClientChain.sdk_threads)
  end
end
