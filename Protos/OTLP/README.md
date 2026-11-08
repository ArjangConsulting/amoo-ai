# OpenTelemetry protocol (OTLP) trace protos

Vendored, unmodified from [opentelemetry-proto v1.11.1](https://github.com/open-telemetry/opentelemetry-proto/tree/v1.11.1)
(Apache-2.0). Only the files the trace exporter needs are included. `make protos` generates their Swift
into `Sources/OTLP/Generated` (the `OTLP` target, used by `AmooTelemetry`); they are not part of the
companion contract and are never copied to the companion apps.

To update, replace the files from a newer tag and run `make protos`.
