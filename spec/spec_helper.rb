# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    track_files "lib/**/*.rb"
    add_filter "/version.rb"
    add_filter { |file| !file.filename.start_with?("#{File.expand_path('../lib', __dir__)}/") }
    enable_coverage :branch
    minimum_coverage line: 90
  end
end

require "gritz/otel"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
