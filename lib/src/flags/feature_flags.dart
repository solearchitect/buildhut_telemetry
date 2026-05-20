import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../otlp/exporter.dart';
import '../otlp/models.dart';
import 'eval_batcher.dart';

/// A feature flag definition fetched from BuildHut.
class FlagDefinition {
  const FlagDefinition({
    required this.name,
    this.description,
    required this.defaultEnabled,
  });

  final String name;
  final String? description;
  final bool defaultEnabled;
}

/// Client for fetching, evaluating, and reporting BuildHut feature flags.
///
/// Flags are fetched from `GET /v1/flags` and cached in memory. Evaluations
/// are reported in batches to `POST /v1/flags/eval`. Each evaluation is also
/// traced as a DEBUG-level OTLP log record via the exporter.
///
/// Usage:
/// ```dart
/// final flagClient = FeatureFlagClient(
///   exporter: exporter,
///   config: exporterConfig,
///   localOverrides: {'new-ui': true},
///   gitBranch: 'main',
///   version: '1.2.0',
/// )..start();
///
/// if (flagClient.isEnabled('new-checkout')) {
///   showNewCheckout();
/// }
///
/// await flagClient.close();
/// ```
class FeatureFlagClient {
  FeatureFlagClient({
    required OtlpExporter exporter,
    required BuildhutExporterConfig config,
    Map<String, bool>? localOverrides,
    this.gitBranch,
    this.version,
    this.refreshInterval = const Duration(minutes: 5),
  })  : _exporter = exporter,
        _config = config,
        _localOverrides = localOverrides ?? const {} {
    _batcher = EvalBatcher(
      config: _config,
      gitBranch: gitBranch,
      version: version,
    );
    _cacheHeadersAndUri();
  }

  final OtlpExporter _exporter;
  final BuildhutExporterConfig _config;
  final Map<String, bool> _localOverrides;
  final String? gitBranch;
  final String? version;
  final Duration refreshInterval;

  late final EvalBatcher _batcher;
  late final Map<String, String> _cachedHeaders;
  late final Uri _flagsUri;

  Timer? _refreshTimer;
  bool _closed = false;
  bool _loaded = false;

  /// Current flag cache keyed by flag name.
  final Map<String, FlagDefinition> _flags = {};

  /// Whether flags have been successfully fetched at least once.
  bool get isLoaded => _loaded;

  /// All cached flag definitions.
  List<FlagDefinition> get allFlags => List.unmodifiable(_flags.values);

  // ---- Lifecycle -----------------------------------------------------------

  /// Start the periodic refresh timer and perform the initial fetch.
  void start() {
    if (_closed) return;
    refresh(); // fire-and-forget initial fetch
    _refreshTimer = Timer.periodic(refreshInterval, (_) {
      if (!_closed) refresh();
    });
  }

  /// Flush pending evaluations and stop the refresh timer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _batcher.flush();
  }

  // ---- Fetch ---------------------------------------------------------------

  /// Fetch the latest flag definitions from BuildHut.
  Future<void> refresh() async {
    if (_closed) return;

    final client = http.Client();
    try {
      final response = await client
          .get(_flagsUri, headers: _cachedHeaders)
          .timeout(_config.timeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final flagsJson = json['flags'] as List<dynamic>;

        _flags.clear();
        for (final f in flagsJson) {
          final map = f as Map<String, dynamic>;
          final def = FlagDefinition(
            name: map['name'] as String,
            description: map['description'] as String?,
            defaultEnabled: map['defaultEnabled'] as bool,
          );
          _flags[def.name] = def;
        }

        _loaded = true;

        _log(
          Severity.info,
          'Feature flags refreshed',
          attributes: {
            'feature_flag.count': _flags.length,
          },
        );
      } else {
        _log(
          Severity.warn,
          'Failed to fetch feature flags',
          attributes: {
            'http.status_code': response.statusCode,
          },
        );
      }
    } catch (e) {
      _log(
        Severity.warn,
        'Failed to fetch feature flags',
        attributes: {'error.message': e.toString()},
      );
    } finally {
      client.close();
    }
  }

  // ---- Evaluate ------------------------------------------------------------

  /// Evaluate a feature flag synchronously.
  ///
  /// Returns the value from [localOverrides] if the flag name is present
  /// there, otherwise the `defaultEnabled` value from the server, otherwise
  /// `false` if the flag is unknown or flags haven't been loaded yet.
  ///
  /// Each evaluation is traced as a DEBUG-level OTLP log record and queued
  /// for batch reporting to `POST /v1/flags/eval`.
  bool isEnabled(String name, {Map<String, dynamic>? context}) {
    final source = _evaluateSource(name);
    final enabled = _evaluate(name);

    _batcher.add(FlagEval(
      flagName: name,
      enabled: enabled,
      context: context,
    ));

    _log(
      Severity.debug,
      'Feature flag evaluated',
      attributes: {
        'feature_flag.name': name,
        'feature_flag.enabled': enabled,
        'feature_flag.source': source,
      },
    );

    return enabled;
  }

  /// Get a cached flag definition by name, or `null` if not found.
  FlagDefinition? getFlag(String name) => _flags[name];

  // ---- Internal ------------------------------------------------------------

  bool _evaluate(String name) {
    if (_localOverrides.containsKey(name)) {
      return _localOverrides[name]!;
    }
    return _flags[name]?.defaultEnabled ?? false;
  }

  String _evaluateSource(String name) {
    if (_localOverrides.containsKey(name)) return 'override';
    if (_flags.containsKey(name)) return 'server';
    return 'default';
  }

  void _log(Severity severity, String message, {Map<String, Object?>? attributes}) {
    final now = DateTime.now();
    final nanoTs = (now.microsecondsSinceEpoch * 1000).toString();

    _exporter.emitLog(OtlpLogRecord(
      timeUnixNano: nanoTs,
      observedTimeUnixNano: nanoTs,
      severityNumber: severity.number,
      severityText: severity.text,
      body: {'message': message},
      attributes: {
        'logger.scope': 'FeatureFlagClient',
        ...?attributes,
      },
    ));
  }

  void _cacheHeadersAndUri() {
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
    _flagsUri = Uri.parse('$base/v1/flags');
  }
}
