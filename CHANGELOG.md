## 0.1.3

- Lower dart sdk version constraint

## 0.1.2

- Update repository URLs to solearchitect/buildhut_telemetry
- Update README install version

## 0.1.1

- Add missing example main
- Add feature flag module

## 0.1.0

- Initial release.
- OTLP/JSON v1 log, trace, and metric exporter with configurable endpoints,
  auth headers, batching, and retry with exponential backoff.
- `BuildhutLogger` with severity levels (TRACE–FATAL), scoped loggers,
  trace-context correlation, and error/stackTrace capture.
- `FrameRateTracer` using Flutter `FrameTiming` callbacks — reports FPS,
  average/max frame time, jank count, and missed-vsync count as OTLP metrics.
- `SpanTracer` for distributed traces with parent-child spans, events, status,
  and auto-timing via `withSpan()`.
- Battery-efficient design for low-spec Android:
  serialized HTTP sends, circuit breaker, buffer cap, background throttling,
  cached headers/URIs, deferred flush, short-lived HTTP clients.
- Full OpenTelemetry API compatibility (see README for field-level mapping).
