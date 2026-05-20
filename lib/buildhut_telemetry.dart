/// BuildHut Telemetry — OpenTelemetry log pusher, frame-rate tracer, and
/// structured logger for Flutter apps.
///
/// Quick start:
/// ```dart
/// import 'package:buildhut_telemetry/buildhut_telemetry.dart';
///
/// void main() {
///   final exporter = OtlpExporter(BuildhutExporterConfig(
///     endpoint: 'https://buildhut.example.com',
///     secret: 'your-32-char-hex-secret',
///     appName: 'my-app',
///     serviceVersion: '1.0.0',
///   ))..start();
///
///   final logger = BuildhutLogger(exporter: exporter);
///   logger.info('Hello BuildHut!');
///
///   final fpsTracer = FrameRateTracer(exporter: exporter)..start();
///
///   // ... your app runs ...
///
///   fpsTracer.stop();
///   exporter.close(); // flush & tear down
/// }
/// ```
library;

// OTLP models
export 'src/otlp/models.dart'
    show
        Severity,
        OtlpAttribute,
        OtlpLogRecord,
        OtlpSpan,
        OtlpStatus,
        OtlpSpanEvent,
        OtlpSpanLink,
        OtlpMetricDataPoint,
        OtlpMetric,
        buildLogsExportRequest,
        buildTracesExportRequest,
        buildMetricsExportRequest;

// OTLP exporter
export 'src/otlp/exporter.dart'
    show BuildhutExporterConfig, OtlpExporter, ExportResult;

// Frame-rate tracer
export 'src/tracing/frame_tracer.dart'
    show FrameRateTracer, FpsSnapshot, FpsSnapshotCallback;

// Span tracer
export 'src/tracing/span_tracer.dart'
    show SpanTracer, ActiveSpan, IdGenerator;

// Logger
export 'src/logging/buildhut_logger.dart' show BuildhutLogger, LogLevel;

// Feature flags
export 'src/flags/feature_flags.dart'
    show FeatureFlagClient, FlagDefinition;
export 'src/flags/eval_batcher.dart' show FlagEval;
