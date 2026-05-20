import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Configuration for the BuildHut OTLP exporter.
class BuildhutExporterConfig {
  const BuildhutExporterConfig({
    required this.endpoint,
    required this.secret,
    this.appName,
    this.serviceVersion,
    this.resourceAttributes,
    this.logsPath = '/v1/logs',
    this.tracesPath = '/v1/traces',
    this.metricsPath = '/v1/metrics',
    this.authHeader = 'Authorization',
    this.authScheme = 'Bearer',
    this.headers = const {},
    this.flushInterval = const Duration(seconds: 30),
    this.maxBatchSize = 50,
    this.maxBufferSize = 500,
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 5),
    this.backgroundFlushMultiplier = 4,
    this.circuitBreakerThreshold = 3,
  });

  /// Base URL of the BuildHut instance, e.g. `https://buildhut.example.com`.
  final String endpoint;

  /// Telemetry secret for the app (from BuildHut dashboard).
  final String secret;

  /// App name. If set, sent as `service.name` in resource attributes.
  /// Can also be set via the `X-App-Name` header or `?app=` query param.
  final String? appName;

  /// Service version included in resource attributes.
  final String? serviceVersion;

  /// Extra resource attributes to include in every export.
  final Map<String, Object?>? resourceAttributes;

  /// Path appended to [endpoint] for OTLP log ingestion.
  /// Defaults to `/v1/logs` (BuildHut standard).
  final String logsPath;

  /// Path appended to [endpoint] for OTLP trace ingestion.
  /// Defaults to `/v1/traces` (BuildHut standard).
  final String tracesPath;

  /// Path appended to [endpoint] for OTLP metric ingestion.
  /// Defaults to `/v1/metrics` (BuildHut standard).
  final String metricsPath;

  /// HTTP header used to transmit the auth credential.
  /// Defaults to `Authorization`. Set to e.g. `X-Secret` to use
  /// a custom header instead.
  final String authHeader;

  /// Auth scheme prepended to the secret value.
  /// Defaults to `Bearer`. Set to empty string to send the raw secret
  /// without a scheme.
  final String authScheme;

  /// Additional HTTP headers to include in every request.
  /// These are merged after the auth and content-type headers,
  /// allowing overrides of any default header.
  final Map<String, String> headers;

  /// How often to flush buffered records when the app is in foreground.
  ///
  /// Defaults to 30 seconds to reduce radio wake-ups on mobile devices.
  /// The first flush occurs when the timer fires, not at start-up.
  final Duration flushInterval;

  /// Max records to accumulate before triggering a mid-interval flush.
  final int maxBatchSize;

  /// Hard cap on buffer size. When exceeded, oldest records are dropped.
  /// This prevents unbounded memory growth if the network is unavailable.
  final int maxBufferSize;

  /// Max retry attempts per failed request. Keep low on mobile to
  /// conserve battery.
  final int maxRetries;

  /// Base delay for exponential backoff on retries.
  final Duration retryBaseDelay;

  /// HTTP request timeout. Keep short on mobile to avoid holding
  /// the radio active.
  final Duration timeout;

  /// When the app goes to background, the flush interval is multiplied
  /// by this value to reduce network activity. Set to 0 to disable
  /// background flushing entirely.
  final int backgroundFlushMultiplier;

  /// Number of consecutive send failures before entering circuit-breaker
  /// mode. In circuit-breaker mode, buffered data is silently dropped
  /// until a successful send resets the counter.
  final int circuitBreakerThreshold;
}

/// Result of an export attempt.
class ExportResult {
  const ExportResult({
    this.success = true,
    this.statusCode,
    this.errorMessage,
    this.rejectedCount = 0,
    this.droppedRecords = 0,
  });

  final bool success;
  final int? statusCode;
  final String? errorMessage;
  final int rejectedCount;

  /// Number of records dropped due to buffer overflow or circuit breaker.
  final int droppedRecords;

  @override
  String toString() {
    if (success && droppedRecords == 0) return 'ExportResult(ok)';
    return 'ExportResult(success=$success, status=$statusCode, '
        'dropped=$droppedRecords, error=$errorMessage)';
  }
}

/// Battery-efficient OTLP exporter for mobile devices.
///
/// Key optimizations for low-spec Android:
/// - **Serialized sends**: only one HTTP request in flight at a time, so the
///   cellular/Wi-Fi radio can sleep between flushes.
/// - **Lazy flush**: auto-flush on timer, not on every emit. Mid-interval
///   flush is deferred to the next timer tick rather than firing immediately.
/// - **Circuit breaker**: stops trying after repeated failures, avoiding
///   wasted radio wake-ups when the server is unreachable.
/// - **Buffer cap**: oldest records are silently dropped when the buffer
///   exceeds [BuildhutExporterConfig.maxBufferSize] to avoid OOM.
/// - **Background throttle**: flush interval is multiplied by
///   [BuildhutExporterConfig.backgroundFlushMultiplier] when the app
///   is backgrounded, or disabled entirely if set to 0.
/// - **Cached headers & URI**: avoids per-request allocations.
/// - **Minimal retries**: defaults to 2 retries with a 2s base delay
///   instead of aggressive retry.
class OtlpExporter {
  OtlpExporter(this._config) {
    _logsBuffer = <OtlpLogRecord>[];
    _spansBuffer = <OtlpSpan>[];
    _metricsBuffer = <OtlpMetric>[];
    _cacheHeadersAndUris();
  }

  final BuildhutExporterConfig _config;

  // Pre-cached values to avoid repeated allocation.
  late final Map<String, String> _cachedHeaders;
  late final Uri _logsUri;
  late final Uri _tracesUri;
  late final Uri _metricsUri;

  late List<OtlpLogRecord> _logsBuffer;
  late List<OtlpSpan> _spansBuffer;
  late List<OtlpMetric> _metricsBuffer;

  Timer? _flushTimer;
  bool _closed = false;
  bool _sending = false; // serializes HTTP requests
  bool _flushNeeded = false; // deferred mid-interval flush
  int _consecutiveFailures = 0; // circuit breaker counter
  bool _isBackground = false;

  // Counters for dropped records across all buffers.
  int _totalDropped = 0;

  // ---- Lifecycle -----------------------------------------------------------

  /// Start the periodic flush timer.
  void start() {
    _restartTimer();
  }

  /// Flush any buffered data and tear down.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  /// Notify the exporter that the app moved to the background.
  ///
  /// Call this from `WidgetsBindingObserver.didChangeAppLifecycleState`
  /// when `state == AppLifecycleState.paused`. The flush interval is
  /// multiplied by [BuildhutExporterConfig.backgroundFlushMultiplier].
  void onAppBackgrounded() {
    _isBackground = true;
    if (!_closed) _restartTimer();
  }

  /// Notify the exporter that the app returned to the foreground.
  ///
  /// Call this when `state == AppLifecycleState.resumed`. The normal
  /// flush interval is restored.
  void onAppForegrounded() {
    final wasBackground = _isBackground;
    _isBackground = false;
    if (!_closed) {
      _restartTimer();
      // Flush immediately on foreground to send data accumulated while
      // backgrounded, but only if there's actually data.
      if (wasBackground && _hasData) {
        flush();
      }
    }
  }

  bool get _hasData =>
      _logsBuffer.isNotEmpty ||
      _spansBuffer.isNotEmpty ||
      _metricsBuffer.isNotEmpty;

  // ---- Timer ---------------------------------------------------------------

  void _restartTimer() {
    _flushTimer?.cancel();

    final multiplier = _config.backgroundFlushMultiplier;
    if (_isBackground && multiplier <= 0) {
      // Background flushing disabled — don't restart timer.
      return;
    }

    final interval = _isBackground
        ? _config.flushInterval * multiplier
        : _config.flushInterval;

    _flushTimer = Timer.periodic(interval, (_) {
      if (_flushNeeded || _hasData) {
        flush();
        _flushNeeded = false;
      }
    });
  }

  // ---- Flush ---------------------------------------------------------------

  /// Immediately flush all buffered data.
  ///
  /// Sends are serialized — if a flush is already in progress, this is
  /// a no-op (the data will be sent when the current flush completes and
  /// the next timer fires).
  Future<List<ExportResult>> flush() async {
    if (_sending || _closed) return const [];

    // Snapshot and clear buffers atomically.
    final logs = List<OtlpLogRecord>.from(_logsBuffer);
    _logsBuffer.clear();
    final spans = List<OtlpSpan>.from(_spansBuffer);
    _spansBuffer.clear();
    final metrics = List<OtlpMetric>.from(_metricsBuffer);
    _metricsBuffer.clear();

    if (logs.isEmpty && spans.isEmpty && metrics.isEmpty) {
      return const [];
    }

    _sending = true;
    final client = http.Client();
    final dropped = _totalDropped;
    _totalDropped = 0;

    try {
      final results = <ExportResult>[];

      // Send logs → traces → metrics sequentially so the radio can
      // transition between requests instead of parallel wake-ups.
      if (logs.isNotEmpty) {
        results.add(await _exportLogs(client, logs, dropped));
      }
      if (spans.isNotEmpty) {
        results.add(await _exportTraces(client, spans, 0));
      }
      if (metrics.isNotEmpty) {
        results.add(await _exportMetrics(client, metrics, 0));
      }
      return results;
    } finally {
      _sending = false;
      client.close();
    }
  }

  // ---- Buffering -----------------------------------------------------------

  /// Add a log record to the buffer.
  void emitLog(OtlpLogRecord record) {
    if (_closed) return;

    // Circuit breaker: silently drop when open.
    if (_consecutiveFailures >= _config.circuitBreakerThreshold) {
      _totalDropped++;
      return;
    }

    _logsBuffer.add(record);
    _trimBuffer(_logsBuffer);

    if (_logsBuffer.length >= _config.maxBatchSize) {
      // Defer flush to next timer tick instead of firing an HTTP request
      // on the calling thread.
      _flushNeeded = true;
    }
  }

  /// Add a span to the buffer.
  void emitSpan(OtlpSpan span) {
    if (_closed) return;

    if (_consecutiveFailures >= _config.circuitBreakerThreshold) {
      _totalDropped++;
      return;
    }

    _spansBuffer.add(span);
    _trimBuffer(_spansBuffer);

    if (_spansBuffer.length >= _config.maxBatchSize) {
      _flushNeeded = true;
    }
  }

  /// Add a metric to the buffer.
  void emitMetric(OtlpMetric metric) {
    if (_closed) return;

    if (_consecutiveFailures >= _config.circuitBreakerThreshold) {
      _totalDropped++;
      return;
    }

    _metricsBuffer.add(metric);
    _trimBuffer(_metricsBuffer);

    if (_metricsBuffer.length >= _config.maxBatchSize) {
      _flushNeeded = true;
    }
  }

  /// Drop oldest entries if buffer exceeds the hard cap.
  void _trimBuffer(List<dynamic> buffer) {
    if (buffer.length <= _config.maxBufferSize) return;
    final dropCount = buffer.length - _config.maxBufferSize;
    buffer.removeRange(0, dropCount);
    _totalDropped += dropCount;
  }

  // ---- Caching -------------------------------------------------------------

  void _cacheHeadersAndUris() {
    final authValue = _config.authScheme.isNotEmpty
        ? '${_config.authScheme} ${_config.secret}'
        : _config.secret;

    _cachedHeaders = {
      'Content-Type': 'application/json',
      _config.authHeader: authValue,
      if (_config.appName != null) 'X-App-Name': _config.appName!,
      ..._config.headers,
    };

    final base = _config.endpoint.replaceAll(RegExp(r'/$'), '');
    _logsUri = Uri.parse('$base${_config.logsPath}');
    _tracesUri = Uri.parse('$base${_config.tracesPath}');
    _metricsUri = Uri.parse('$base${_config.metricsPath}');
  }

  // ---- Export ---------------------------------------------------------------

  Future<ExportResult> _exportLogs(
    http.Client client,
    List<OtlpLogRecord> records,
    int extraDropped,
  ) async {
    final payload = buildLogsExportRequest(
      serviceName: _config.appName ?? 'unknown',
      serviceVersion: _config.serviceVersion,
      resourceAttributes: _config.resourceAttributes,
      logRecords: records,
      scopeName: 'buildhut_telemetry',
      scopeVersion: '0.1.0',
    );
    final result = await _send(client, _logsUri, payload);
    return ExportResult(
      success: result.success,
      statusCode: result.statusCode,
      errorMessage: result.errorMessage,
      rejectedCount: result.rejectedCount,
      droppedRecords: extraDropped,
    );
  }

  Future<ExportResult> _exportTraces(
    http.Client client,
    List<OtlpSpan> spans,
    int extraDropped,
  ) async {
    final payload = buildTracesExportRequest(
      serviceName: _config.appName ?? 'unknown',
      serviceVersion: _config.serviceVersion,
      resourceAttributes: _config.resourceAttributes,
      spans: spans,
      scopeName: 'buildhut_telemetry',
      scopeVersion: '0.1.0',
    );
    final result = await _send(client, _tracesUri, payload);
    return ExportResult(
      success: result.success,
      statusCode: result.statusCode,
      errorMessage: result.errorMessage,
      rejectedCount: result.rejectedCount,
      droppedRecords: extraDropped,
    );
  }

  Future<ExportResult> _exportMetrics(
    http.Client client,
    List<OtlpMetric> metrics,
    int extraDropped,
  ) async {
    final payload = buildMetricsExportRequest(
      serviceName: _config.appName ?? 'unknown',
      serviceVersion: _config.serviceVersion,
      resourceAttributes: _config.resourceAttributes,
      metrics: metrics,
      scopeName: 'buildhut_telemetry',
      scopeVersion: '0.1.0',
    );
    final result = await _send(client, _metricsUri, payload);
    return ExportResult(
      success: result.success,
      statusCode: result.statusCode,
      errorMessage: result.errorMessage,
      rejectedCount: result.rejectedCount,
      droppedRecords: extraDropped,
    );
  }

  // ---- HTTP ----------------------------------------------------------------

  Future<ExportResult> _send(
    http.Client client,
    Uri uri,
    Map<String, Object?> payload,
  ) async {
    final body = jsonEncode(payload);

    for (var attempt = 0; attempt <= _config.maxRetries; attempt++) {
      try {
        final response = await client
            .post(uri, headers: _cachedHeaders, body: body)
            .timeout(_config.timeout);

        if (response.statusCode == 200) {
          _consecutiveFailures = 0; // reset circuit breaker

          // Only parse JSON body if there is one — saves decode cost on
          // the common fast path where the server returns `{}`.
          if (response.body.isNotEmpty && response.body != '{}') {
            final json =
                jsonDecode(response.body) as Map<String, dynamic>;
            if (json['partialSuccess'] != null) {
              final partial =
                  json['partialSuccess'] as Map<String, dynamic>;
              final rejected = partial['rejectedLogRecords'] ??
                  partial['rejectedSpans'] ??
                  partial['rejectedDataPoints'] ??
                  0;
              return ExportResult(
                success: true,
                statusCode: 200,
                rejectedCount: rejected as int,
                errorMessage: partial['errorMessage'] as String?,
              );
            }
          }
          return const ExportResult(success: true, statusCode: 200);
        }

        // Auth errors are not transient — don't retry.
        if (response.statusCode == 401 || response.statusCode == 403) {
          _consecutiveFailures++;
          return ExportResult(
            success: false,
            statusCode: response.statusCode,
            errorMessage: 'Authentication failed',
          );
        }

        // Server errors: retry with backoff.
        if (response.statusCode >= 500 && attempt < _config.maxRetries) {
          await _backoff(attempt);
          continue;
        }

        _consecutiveFailures++;
        return ExportResult(
          success: false,
          statusCode: response.statusCode,
          errorMessage: response.body,
        );
      } on TimeoutException {
        if (attempt < _config.maxRetries) {
          await _backoff(attempt);
          continue;
        }
        _consecutiveFailures++;
        return const ExportResult(
          success: false,
          errorMessage: 'Request timed out',
        );
      } on http.ClientException {
        // Network unreachable, DNS failure, connection refused — these
        // are transient on mobile. Don't burn battery retrying;
        if (attempt < _config.maxRetries) {
          await _backoff(attempt);
          continue;
        }
        _consecutiveFailures++;
        return const ExportResult(
          success: false,
          errorMessage: 'Network error',
        );
      } catch (e) {
        // Unexpected error — don't retry.
        _consecutiveFailures++;
        return ExportResult(
          success: false,
          errorMessage: e.toString(),
        );
      }
    }

    _consecutiveFailures++;
    return const ExportResult(
      success: false,
      errorMessage: 'Max retries exceeded',
    );
  }

  Future<void> _backoff(int attempt) async {
    final delay = _config.retryBaseDelay * (1 << attempt);
    await Future.delayed(delay);
  }
}
