# buildhut_telemetry

A Flutter library for pushing OpenTelemetry logs, traces, and metrics to a
[BuildHut](https://git.sr.ht/~drzoidberg/Buildhut) instance. Includes a frame-rate
performance tracer and a structured logger.

Built on top of the
[OpenTelemetry Protocol (OTLP)](https://opentelemetry.io/docs/specs/otlp/) JSON
encoding over HTTP. Payloads are compatible with any OTLP/JSON v1 collector, not
just BuildHut.

---

## Features

- **OTLP Log Exporter** -- buffered, batched HTTP transport with configurable
  retry and exponential backoff.
- **Structured Logger** -- severity levels (TRACE through FATAL), scoped
  loggers, trace-context correlation, error/stackTrace capture.
- **Frame-Rate Tracer** -- uses Flutter's `FrameTiming` callbacks for accurate
  build + raster timing; reports FPS, average/max frame time, jank count, and
  missed-vsync count as OTLP metrics.
- **Distributed Traces** -- create parent/child spans with events, status, and
  auto-timing via `SpanTracer.withSpan()`.
- **Custom Metrics** -- emit gauge, sum, and histogram metrics directly.
- **Fully Configurable** -- endpoint paths, auth header, and extra headers are
  all configurable. Works with BuildHut, Jaeger, OTel Collector, or any
  OTLP/JSON v1 endpoint.

## Setup

### 1. Install

Add to your `pubspec.yaml`:

```yaml
dependencies:
  buildhut_telemetry: ^0.1.0
```

### 2. Get your BuildHut credentials

In your BuildHut dashboard, create an app and copy the **telemetry secret**
(32-character hex string). You'll need:

- Your BuildHut instance URL (e.g. `https://buildhut.myorg.com`)
- The telemetry secret

### 3. Initialize the exporter

```dart
import 'package:buildhut_telemetry/buildhut_telemetry.dart';

final exporter = OtlpExporter(BuildhutExporterConfig(
  endpoint: 'https://buildhut.myorg.com',
  secret: 'your-32-char-hex-secret',
  appName: 'my-flutter-app',
  serviceVersion: '1.2.0',
))..start();
```

Call `exporter.close()` when your app shuts down to flush remaining data.

---

## Usage

### Structured Logging

```dart
final logger = BuildhutLogger(exporter: exporter);

// Basic log levels
logger.trace('Entering setup');
logger.debug('Cache miss for key=abc');
logger.info('App started');
logger.warn('Disk usage above 80%');
logger.error('Network request failed', error: e, stackTrace: st);
logger.fatal('Out of memory');

// Scoped loggers -- adds 'logger.scope' attribute automatically
final authLogger = logger.withScope('AuthService');
authLogger.info('User signed in', attributes: {
  'user.id': 42,
  'user.email': 'alice@example.com',
});

// Attach trace context for log-to-span correlation
logger.setTraceContext(traceId: 'abc123...', spanId: 'def456...');
logger.info('Handled within span');
logger.clearTraceContext();

// Filter by minimum level at runtime
logger.minimumLevel = LogLevel.warn;  // only WARN and above are emitted
```

### Frame-Rate Performance Tracing

```dart
final fpsTracer = FrameRateTracer(
  exporter: exporter,
  reportingInterval: const Duration(seconds: 5),
  jankThresholdMs: 16.0,       // flag frames > 16ms as jank
  missedVsyncThresholdMs: 32.0, // flag frames > 32ms as missed vsync
)..start();

// Optional: observe snapshots locally (e.g. show in dev overlay)
fpsTracer.onSnapshot = (snap) {
  debugPrint('${snap.fps} fps, ${snap.jankFrames} jank frames');
};

// Later, stop tracking
fpsTracer.stop();
```

#### Metrics emitted by the frame tracer

| Metric name | Type | Description |
|---|---|---|
| `app.fps` | Gauge | Frames per second in the reporting window |
| `app.frame.time.avg_ms` | Gauge | Average frame time (ms) |
| `app.frame.time.max_ms` | Gauge | Max frame time (ms) |
| `app.frame.jank_count` | Sum (monotonic) | Number of janky frames (> `jankThresholdMs`) |
| `app.frame.missed_vsync` | Sum (monotonic) | Number of frames that missed vsync (> `missedVsyncThresholdMs`) |

When jank is detected, a WARN-level OTLP log record is also emitted with the
full snapshot details.

### Distributed Traces

```dart
final tracer = SpanTracer(exporter: exporter);

// Manual span lifecycle
final span = tracer.startSpan('database.query', attributes: {
  'db.system': 'sqlite',
  'db.operation': 'SELECT',
});
// ... do work ...
span.addEvent('cache_miss', attributes: {'key': 'user:42'});
span.end();

// Automatic span with error handling
try {
  await tracer.withSpan('http.request', (span) async {
    span.addEvent('dns_resolved');
    final response = await httpClient.get(uri);
    span.addEvent('response_received', attributes: {
      'http.status_code': response.statusCode,
    });
    return response;
  }, attributes: {
    'http.method': 'GET',
    'http.url': uri.toString(),
  });
} catch (e) {
  // span was already ended with ERROR status and exception event
}

// Parent-child spans
final parent = tracer.startSpan('operation');
final child = tracer.startSpan(
  'subtask',
  parentSpanId: parent.spanId,
);
child.end();
parent.end();
```

### Custom Metrics

```dart
// Gauge: point-in-time value
exporter.emitMetric(OtlpMetric(
  name: 'app.memory.used_mb',
  description: 'Currently used memory in megabytes',
  unit: 'MB',
  gaugeDataPoints: [
    OtlpMetricDataPoint(
      timeUnixNano: (DateTime.now().microsecondsSinceEpoch * 1000).toString(),
      asDouble: 128.5,
    ),
  ],
));

// Sum: monotonically increasing counter
exporter.emitMetric(OtlpMetric(
  name: 'app.requests.total',
  description: 'Total HTTP requests',
  unit: '1',
  sumDataPoints: [
    OtlpMetricDataPoint(
      timeUnixNano: (DateTime.now().microsecondsSinceEpoch * 1000).toString(),
      asDouble: 1503,
    ),
  ],
  sumIsMonotonic: true,
  sumAggregationTemporality: 2, // CUMULATIVE
));
```

### Feature Flags

```dart
final flagClient = FeatureFlagClient(
  exporter: exporter,
  config: exporterConfig,
  localOverrides: {'new-ui': true},  // force on in dev
  gitBranch: 'main',
  version: '1.2.0',
)..start();

// Synchronous check — returns override value if set, otherwise
// the server's defaultEnabled, otherwise false.
if (flagClient.isEnabled('new-checkout')) {
  showNewCheckout();
}

// Pass evaluation context for analytics breakdown
flagClient.isEnabled('search-v2', context: {
  'user.tier': 'premium',
  'region': 'eu-west',
});

// Inspect raw flag metadata
final flag = flagClient.getFlag('new-checkout');
print(flag?.description);

// Shut down — flushes pending evaluations
await flagClient.close();
```

The client fetches flags from `GET /v1/flags` on start and refreshes on a
configurable interval (default 5 minutes). Each `isEnabled()` call is
traced as a DEBUG-level OTLP log record and queued for batch reporting to
`POST /v1/flags/eval`. Evaluations include the flag name, result, source
(override / server / default), and optional context.

| Method / Property | Description |
|---|---|
| `start()` | Begin periodic refresh timer + initial fetch |
| `refresh()` | Manually fetch latest flags from server |
| `isEnabled(name, {context})` | Evaluate a flag; auto-traces and reports |
| `getFlag(name)` | Get raw `FlagDefinition` metadata |
| `allFlags` | All cached flag definitions |
| `isLoaded` | Whether flags have been fetched at least once |
| `close()` | Flush pending evals and stop refresh timer |

### Advanced Exporter Configuration

```dart
final exporter = OtlpExporter(BuildhutExporterConfig(
  // --- Required ---
  endpoint: 'https://buildhut.myorg.com',
  secret: 'abc123def456...',

  // --- Identity ---
  appName: 'my-flutter-app',         // service.name in resource attributes
  serviceVersion: '1.2.0',           // service.version in resource attributes
  resourceAttributes: {              // extra resource attributes
    'deployment.environment': 'prod',
    'host.name': 'device-abc',
  },

  // --- Endpoint paths (defaults match BuildHut / OTLP v1) ---
  logsPath: '/v1/logs',
  tracesPath: '/v1/traces',
  metricsPath: '/v1/metrics',

  // --- Authorization ---
  authHeader: 'Authorization',       // header name for the credential
  authScheme: 'Bearer',              // scheme prefix (set '' for raw secret)
  // Result: Authorization: Bearer <secret>
  //
  // Alternative: use X-Secret header without a scheme
  //   authHeader: 'X-Secret',
  //   authScheme: '',

  // --- Custom headers (merged into every request) ---
  headers: {
    'X-Org-Id': 'my-org',
  },

  // --- Transport tuning ---
  flushInterval: const Duration(seconds: 5),  // periodic flush interval
  maxBatchSize: 50,                           // auto-flush threshold
  maxRetries: 3,                              // retries on 5xx / timeout
  retryBaseDelay: const Duration(seconds: 1), // exponential backoff base
  timeout: const Duration(seconds: 10),       // per-request timeout
))..start();
```

### Full App Integration Example

```dart
import 'package:flutter/material.dart';
import 'package:buildhut_telemetry/buildhut_telemetry.dart';

late final OtlpExporter exporter;
late final BuildhutLogger logger;
late final FrameRateTracer fpsTracer;

void main() {
  exporter = OtlpExporter(BuildhutExporterConfig(
    endpoint: const String.fromEnvironment('BUILDHUT_ENDPOINT'),
    secret: const String.fromEnvironment('BUILDHUT_SECRET'),
    appName: 'my-app',
    serviceVersion: '1.0.0',
  ))..start();

  logger = BuildhutLogger(exporter: exporter, minimumLevel: LogLevel.info);
  fpsTracer = FrameRateTracer(exporter: exporter);

  logger.info('Application starting');

  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    fpsTracer.start();
    logger.info('MyApp initialized');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    logger.info('Lifecycle changed', attributes: {
      'lifecycle.state': state.name,
    });
  }

  @override
  void dispose() {
    fpsTracer.stop();
    exporter.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('BuildHut Telemetry Demo')),
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final tracer = SpanTracer(exporter: exporter);
              try {
                await tracer.withSpan('button.tap', (span) async {
                  span.addEvent('pressed');
                  await Future.delayed(const Duration(milliseconds: 200));
                  logger.info('Button pressed');
                });
              } catch (e) {
                logger.error('Button handler failed', error: e);
              }
            },
            child: const Text('Tap me'),
          ),
        ),
      ),
    );
  }
}
```

---

## OpenTelemetry API Compatibility

This library implements the OTLP/JSON v1 protocol. Below is a mapping of
OpenTelemetry concepts to the Dart classes provided by this package.

### Signals

| OTel Signal | OTLP Endpoint | Dart Class | Export Method |
|---|---|---|---|
| Logs | `POST /v1/logs` | `OtlpLogRecord` | `exporter.emitLog()` |
| Traces | `POST /v1/traces` | `OtlpSpan` | `exporter.emitSpan()` |
| Metrics | `POST /v1/metrics` | `OtlpMetric` | `exporter.emitMetric()` |

### Log Record Fields

| OTLP Field | `OtlpLogRecord` property | Supported |
|---|---|---|
| `timeUnixNano` | `timeUnixNano` | Yes |
| `observedTimeUnixNano` | `observedTimeUnixNano` | Yes |
| `severityNumber` | `severityNumber` | Yes |
| `severityText` | `severityText` | Yes |
| `body` (AnyValue) | `body` | Yes |
| `attributes` | `attributes` | Yes |
| `droppedAttributesCount` | `droppedAttributesCount` | Yes |
| `flags` | `flags` | Yes |
| `traceId` | `traceId` | Yes |
| `spanId` | `spanId` | Yes |

### Span Fields

| OTLP Field | `OtlpSpan` property | Supported |
|---|---|---|
| `traceId` | `traceId` | Yes |
| `spanId` | `spanId` | Yes |
| `parentSpanId` | `parentSpanId` | Yes |
| `name` | `name` | Yes |
| `kind` | `kind` | Yes |
| `startTimeUnixNano` | `startTimeUnixNano` | Yes |
| `endTimeUnixNano` | `endTimeUnixNano` | Yes |
| `attributes` | `attributes` | Yes |
| `events[]` | `events` | Yes |
| `links[]` | `links` | Yes |
| `status` | `status` | Yes |
| `flags` | `flags` | Yes |

### Span Kind Values

| Value | Constant | Description |
|---|---|---|
| 0 | `SPAN_KIND_INTERNAL` | Internal operation |
| 1 | `SPAN_KIND_SERVER` | Server-side RPC |
| 2 | `SPAN_KIND_CLIENT` | Client-side RPC (default in `startSpan`) |
| 3 | `SPAN_KIND_PRODUCER` | Message producer |
| 4 | `SPAN_KIND_CONSUMER` | Message consumer |

### Status Codes

| Value | `OtlpStatus.code` | Description |
|---|---|---|
| 0 | `UNSET` | No status set |
| 1 | `OK` | Operation succeeded |
| 2 | `ERROR` | Operation failed |

### Metric Types

| OTLP Type | `OtlpMetric` property | Supported |
|---|---|---|
| Gauge | `gaugeDataPoints` | Yes |
| Sum | `sumDataPoints` + `sumAggregationTemporality` + `sumIsMonotonic` | Yes |
| Histogram | -- | No (not yet implemented) |

### Metric Data Point Fields

| OTLP Field | `OtlpMetricDataPoint` property | Supported |
|---|---|---|
| `startTimeUnixNano` | `startTimeUnixNano` | Yes |
| `timeUnixNano` | `timeUnixNano` | Yes |
| `asDouble` | `asDouble` | Yes |
| `asInt` | `asInt` | Yes |
| `attributes` | `attributes` | Yes |
| `flags` | `flags` | Yes |

### Severity Levels

| `LogLevel` | `Severity` | Number | Text |
|---|---|---|---|
| `LogLevel.trace` | `Severity.trace` | 1 | TRACE |
| `LogLevel.debug` | `Severity.debug` | 5 | DEBUG |
| `LogLevel.info` | `Severity.info` | 9 | INFO |
| `LogLevel.warn` | `Severity.warn` | 13 | WARN |
| `LogLevel.error` | `Severity.error` | 17 | ERROR |
| `LogLevel.fatal` | `Severity.fatal` | 21 | FATAL |

Fine-grained sub-levels (2-4, 6-8, 10-12, 14-16, 18-20, 22-24) are available
via `Severity.trace2` .. `Severity.fatal4`.

### Resource & Scope Envelope

| OTLP Concept | Mapping |
|---|---|
| `Resource.attributes` | `service.name` set from `BuildhutExporterConfig.appName`, `service.version` from `serviceVersion`, plus `resourceAttributes` |
| `InstrumentationScope.name` | Always `buildhut_telemetry` |
| `InstrumentationScope.version` | Library version (`0.1.0`) |

### Transport

| Feature | Supported | Notes |
|---|---|---|
| OTLP/JSON over HTTP | Yes | `Content-Type: application/json` |
| OTLP/Protobuf | No | JSON only |
| Batcher with auto-flush | Yes | Timer-based + size threshold |
| Retry with backoff | Yes | Exponential, configurable |
| Partial success handling | Yes | Parses `partialSuccess` response |
| `grpc` transport | No | HTTP/JSON only |
| Compression (gzip) | No | Not yet implemented |

---

## API Reference

### `BuildhutExporterConfig`

| Property | Type | Default | Description |
|---|---|---|---|
| `endpoint` | `String` | -- | Base URL of the OTLP receiver |
| `secret` | `String` | -- | Auth credential |
| `appName` | `String?` | `null` | `service.name` in resource attrs + `X-App-Name` header |
| `serviceVersion` | `String?` | `null` | `service.version` in resource attrs |
| `resourceAttributes` | `Map<String, Object?>?` | `null` | Extra resource attributes |
| `logsPath` | `String` | `/v1/logs` | Path appended to `endpoint` for logs |
| `tracesPath` | `String` | `/v1/traces` | Path appended to `endpoint` for traces |
| `metricsPath` | `String` | `/v1/metrics` | Path appended to `endpoint` for metrics |
| `authHeader` | `String` | `Authorization` | HTTP header for the credential |
| `authScheme` | `String` | `Bearer` | Scheme prefix (empty string = raw) |
| `headers` | `Map<String, String>` | `{}` | Extra HTTP headers |
| `flushInterval` | `Duration` | `5s` | Periodic flush timer |
| `maxBatchSize` | `int` | `50` | Records before auto-flush |
| `maxRetries` | `int` | `3` | Retry count for transient errors |
| `retryBaseDelay` | `Duration` | `1s` | Backoff base delay |
| `timeout` | `Duration` | `10s` | Per-request timeout |

### `OtlpExporter`

| Method | Returns | Description |
|---|---|---|
| `start()` | `void` | Start periodic flush timer |
| `close()` | `Future<void>` | Flush remaining data, stop timer, close HTTP client |
| `flush()` | `Future<List<ExportResult>>` | Immediately send all buffered data |
| `emitLog(record)` | `void` | Buffer a log record |
| `emitSpan(span)` | `void` | Buffer a span |
| `emitMetric(metric)` | `void` | Buffer a metric |

### `BuildhutLogger`

| Method / Property | Description |
|---|---|
| `trace(msg, {error, stackTrace, attributes})` | Emit TRACE-level log |
| `debug(msg, ...)` | Emit DEBUG-level log |
| `info(msg, ...)` | Emit INFO-level log |
| `warn(msg, ...)` | Emit WARN-level log |
| `error(msg, ...)` | Emit ERROR-level log |
| `fatal(msg, ...)` | Emit FATAL-level log |
| `minimumLevel` | Get/set the minimum level (below this, records are dropped) |
| `isLoggable(level)` | Check if a level would be emitted |
| `withScope(name)` | Create a child logger with a fixed scope |
| `withAttributes(attrs)` | Create a child logger with merged default attributes |
| `setTraceContext({traceId, spanId})` | Attach trace correlation to subsequent logs |
| `clearTraceContext()` | Remove trace correlation |

### `FrameRateTracer`

| Method / Property | Description |
|---|---|
| `start()` | Begin tracking frame timing |
| `stop()` | Stop tracking, flush final snapshot |
| `isRunning` | Whether the tracer is active |
| `onSnapshot` | Callback for real-time `FpsSnapshot` observation |
| `reportingInterval` | How often snapshots are emitted |
| `jankThresholdMs` | Frame time above this is "jank" (default 16ms) |
| `missedVsyncThresholdMs` | Frame time above this is "missed vsync" (default 32ms) |

### `SpanTracer`

| Method | Returns | Description |
|---|---|---|
| `startSpan(name, {parentSpanId, attributes, kind})` | `ActiveSpan` | Create and start a new span |
| `withSpan(name, action, {parentSpanId, attributes, kind})` | `Future<T>` | Run async work inside a span, auto-end with status |
| `traceId` | `String` | The shared trace ID for all spans |

### `ActiveSpan`

| Method / Property | Description |
|---|---|
| `traceId` | Hex trace ID |
| `spanId` | Hex span ID |
| `parentSpanId` | Hex parent span ID (if any) |
| `name` | Span operation name |
| `addEvent(name, {attributes})` | Add a timed event |
| `setStatus(OtlpStatus)` | Set OK/ERROR status |
| `end()` | End the span and emit it |

---

## License

MIT
