# Gritz OpenTelemetry

Server and client spans and worker OTLP metrics for [Gritz](https://github.com/gritzrpc/gritz). SDK providers and exporters start in worker boot hooks, after fork. This optional integration depends on `gritz-core`; applications choose their transport separately.

Requires CRuby 3.3 or later and Gritz 0.5.0. The OpenTelemetry metrics SDK is currently alpha; this gem pins its supported minor versions.

## Installation and configuration

```ruby
gem "gritz", "~> 0.5.0"
gem "gritz-otel", "~> 0.2.0"
```

In the Gritz configuration file:

```ruby
require "gritz/otel"

metrics_backend :otlp
opentelemetry do |sdk|
  sdk.service_name = "greeter"
end
```

Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318/` for OTLP/HTTP protobuf. Standard exporter endpoint, headers, certificate and compression environment variables are supported. Traces go to `/v1/traces` and metrics to `/v1/metrics`. With the default `metrics_backend :pipe`, the integration adds tracing while retaining the built-in Prometheus metrics.

For a configuration object, use `Gritz::Otel.install(config) { |sdk| ... }`. The SDK block executes in each worker; create custom processors or exporters inside that block. Register the integration before starting the server. The integration owns one SDK configuration per worker process and closes its providers after application shutdown hooks and final RPC observations.

## Tracing

Server spans surround complete dispatch, including streaming and error mapping. `Gritz::Client` spans surround complete outgoing calls and response consumption, with native cancellation on early exit. Incoming W3C `traceparent` and `tracestate` are extracted and outgoing child contexts are injected. Lazy clients retain the context captured when the call was created. Incoming credentials and baggage are not automatically forwarded.

Spans include the service, method and final gRPC status. They omit protobuf payloads and exception messages. See the [client guide](https://github.com/gritzrpc/gritz-core/blob/main/docs/guides/clients.md).

## Worker metrics

With `metrics_backend :otlp`, each worker records:

| Instrument | Meaning |
| --- | --- |
| `gritz.rpc.server.duration` | Completed RPC duration, in seconds |
| `gritz.rpc.server.requests`, `gritz.rpc.server.responses` | Messages per completed RPC |
| `gritz.rpc.server.rejected` | Overload rejections |
| `gritz.worker.inflight`, `gritz.worker.busy_threads`, `gritz.worker.capacity` | Worker occupancy and capacity |
| `gritz.worker.state` | Current lifecycle state |
| `gritz.worker.rss_bytes`, `gritz.worker.pss_bytes` | Actual Linux process memory |

Worker PID and index identify each observation; service/method/status identify RPC histograms. The collector receives cumulative SDK metrics from individual workers. Master restart counts and framework-wide totals remain available through Admin `/metrics`; OTLP continues to mirror RPC deltas to the built-in pipe backend.

Worker status heartbeats drive official SDK metric collection and HTTP export. Each heartbeat export is bounded by the smallest of one second, half `status_interval`, and a quarter of `shutdown_timeout`. A failed observation or export retains pipe data and does not fail the RPC. Final export and provider shutdown share the remaining graceful shutdown budget; telemetry may be dropped when that budget expires.

## Development and releases

```sh
bundle install
COVERAGE=1 bundle exec rake
bundle exec rubocop
bundle exec bundler-audit check --update
bundle exec rake build
```

Tests include a real Linux three-service chain with an OTLP/HTTP protobuf collector. Core and native development dependencies use their Git repositories; runtime dependencies use published gems. See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and the [release guide](docs/guides/releasing.md).

See the [three-service integration report](docs/reports/T4-08-client-chain.md) for the completion checks and reproduction commands.

The 0.1.0 release supports Gritz 0.4.0; the 0.2.0 release supports Gritz 0.5.0.

## License

[MIT](LICENSE.txt).
