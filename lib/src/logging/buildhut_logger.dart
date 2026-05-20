import '../otlp/models.dart';
import '../otlp/exporter.dart';

/// A log level that maps to OTLP severity numbers.
enum LogLevel {
  trace(Severity.trace),
  debug(Severity.debug),
  info(Severity.info),
  warn(Severity.warn),
  error(Severity.error),
  fatal(Severity.fatal);

  const LogLevel(this.severity);

  final Severity severity;
}

/// Logger that sends structured log records to BuildHut via OTLP.
///
/// Supports hierarchical scopes for contextual logging and attaches
/// optional trace/span context for correlation.
///
/// Usage:
/// ```dart
/// final logger = BuildhutLogger(exporter: exporter);
///
/// logger.info('App started');
/// logger.error('Failed to load config', error: e, stackTrace: st);
///
/// final scoped = logger.withScope('AuthService');
/// scoped.debug('User authenticated', attributes: {'userId': 42});
/// ```
class BuildhutLogger {
  BuildhutLogger({
    required OtlpExporter exporter,
    this.scopeName,
    this.scopeVersion,
    this.defaultAttributes,
    this.minimumLevel = LogLevel.trace,
  }) : _exporter = exporter;

  final OtlpExporter _exporter;

  /// Scope name included in every log record (e.g. class or module name).
  final String? scopeName;

  final String? scopeVersion;

  /// Attributes attached to every log record from this logger.
  final Map<String, Object?>? defaultAttributes;

  /// Minimum log level to actually emit. Records below this are dropped.
  LogLevel minimumLevel;

  /// Current trace context for correlation.
  String? _currentTraceId;
  String? _currentSpanId;

  /// Whether [level] would be emitted given the current [minimumLevel].
  bool isLoggable(LogLevel level) =>
      level.severity.number >= minimumLevel.severity.number;

  // ---- Trace context -------------------------------------------------------

  /// Set the current trace/span context for correlation.
  void setTraceContext({String? traceId, String? spanId}) {
    _currentTraceId = traceId;
    _currentSpanId = spanId;
  }

  /// Clear the current trace context.
  void clearTraceContext() {
    _currentTraceId = null;
    _currentSpanId = null;
  }

  // ---- Scoped logger -------------------------------------------------------

  /// Create a child logger with a fixed scope name.
  BuildhutLogger withScope(String name, {String? version}) {
    return BuildhutLogger(
      exporter: _exporter,
      scopeName: name,
      scopeVersion: version ?? scopeVersion,
      defaultAttributes: {...?defaultAttributes},
      minimumLevel: minimumLevel,
    );
  }

  /// Create a child logger with extra default attributes merged in.
  BuildhutLogger withAttributes(Map<String, Object?> attrs) {
    return BuildhutLogger(
      exporter: _exporter,
      scopeName: scopeName,
      scopeVersion: scopeVersion,
      defaultAttributes: {...?defaultAttributes, ...attrs},
      minimumLevel: minimumLevel,
    );
  }

  // ---- Convenience methods -------------------------------------------------

  void trace(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      _log(LogLevel.trace, message,
          error: error, stackTrace: stackTrace, attributes: attributes);

  void debug(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      _log(LogLevel.debug, message,
          error: error, stackTrace: stackTrace, attributes: attributes);

  void info(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      _log(LogLevel.info, message,
          error: error, stackTrace: stackTrace, attributes: attributes);

  void warn(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      _log(LogLevel.warn, message,
          error: error, stackTrace: stackTrace, attributes: attributes);

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      _log(LogLevel.error, message,
          error: error, stackTrace: stackTrace, attributes: attributes);

  void fatal(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) =>
      _log(LogLevel.fatal, message,
          error: error, stackTrace: stackTrace, attributes: attributes);

  // ---- Core implementation -------------------------------------------------

  void _log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    if (!isLoggable(level)) return;

    final now = DateTime.now();
    final nanoTs = (now.microsecondsSinceEpoch * 1000).toString();

    final mergedAttrs = <String, Object?>{
      if (scopeName != null) 'logger.scope': scopeName,
      ...?defaultAttributes,
      ...?attributes,
    };

    if (error != null) {
      mergedAttrs['error.type'] = error.runtimeType.toString();
      mergedAttrs['error.message'] = error.toString();
    }
    if (stackTrace != null) {
      mergedAttrs['error.stack_trace'] = stackTrace.toString();
    }

    final body = <String, Object?>{
      'message': message,
    };
    if (error != null) {
      body['error'] = error.toString();
    }

    _exporter.emitLog(OtlpLogRecord(
      timeUnixNano: nanoTs,
      observedTimeUnixNano: nanoTs,
      severityNumber: level.severity.number,
      severityText: level.severity.text,
      body: body,
      attributes: mergedAttrs.isNotEmpty ? mergedAttrs : null,
      traceId: _currentTraceId,
      spanId: _currentSpanId,
    ));
  }
}
