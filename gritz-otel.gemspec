# frozen_string_literal: true

require_relative "lib/gritz/otel/version"

Gem::Specification.new do |spec|
  spec.name = "gritz-otel"
  spec.version = Gritz::Otel::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Fork-safe OpenTelemetry integration for Gritz"
  spec.description = "Server and client tracing and worker OTLP metrics for Gritz, initialized after fork."
  spec.homepage = "https://github.com/gritzrpc/gritz-otel"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = "#{spec.homepage}/"
  spec.metadata["source_code_uri"] = "https://github.com/gritzrpc/gritz-otel"
  spec.metadata["changelog_uri"] = "https://github.com/gritzrpc/gritz-otel/blob/main/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "CHANGELOG.md"] }
  spec.require_paths = ["lib"]

  spec.add_dependency "gritz-core", "= 0.9.1"
  spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.35.0"
  spec.add_dependency "opentelemetry-exporter-otlp-metrics", "~> 0.13.0"
  spec.add_dependency "opentelemetry-metrics-sdk", "~> 0.19.0"
  spec.add_dependency "opentelemetry-sdk", "~> 1.13.0"
end
