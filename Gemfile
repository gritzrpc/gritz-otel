# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["GRITZ_RELEASE"] == "1"
  gem "gritz-native", "= 0.9.1", group: :test
else
  gem "gritz-core", git: "https://github.com/gritzrpc/gritz-core.git", branch: "main"
  gem "gritz-native", git: "https://github.com/gritzrpc/gritz-native.git", branch: "main", group: :test
end

group :development, :test do
  gem "bundler-audit", "~> 0.9"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.75"
  gem "simplecov", "~> 0.22.0"
  gem "yard", "~> 0.9"
end
