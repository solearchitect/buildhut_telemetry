import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../otlp/exporter.dart';

/// A single feature flag evaluation to be reported to BuildHut.
class FlagEval {
  const FlagEval({
    required this.flagName,
    required this.enabled,
    this.context,
  });

  final String flagName;
  final bool enabled;
  final Map<String, dynamic>? context;

  Map<String, Object?> toJson({String? gitBranch, String? version}) {
    final json = <String, Object?>{
      'flagName': flagName,
      'enabled': enabled,
    };
    if (gitBranch != null) json['gitBranch'] = gitBranch;
    if (context != null) json['context'] = context;
    if (version != null) json['version'] = version;
    return json;
  }
}

/// Batches flag evaluations and sends them to `POST /v1/flags/eval`.
///
/// Respects the server's 100-evaluations-per-batch limit and reuses the
/// same auth headers and timeout as [OtlpExporter].
class EvalBatcher {
  EvalBatcher({
    required BuildhutExporterConfig config,
    this.gitBranch,
    this.version,
  }) : _config = config {
    _cacheHeadersAndUri();
  }

  final BuildhutExporterConfig _config;
  final String? gitBranch;
  final String? version;

  late final Map<String, String> _cachedHeaders;
  late final Uri _evalUri;

  final List<FlagEval> _buffer = [];

  /// Number of pending evaluations waiting to be flushed.
  int get pendingCount => _buffer.length;

  /// Buffer an evaluation for later batch reporting.
  void add(FlagEval eval) {
    _buffer.add(eval);
  }

  /// Send all buffered evaluations to `POST /v1/flags/eval`.
  ///
  /// Evaluations are sent in chunks of at most 100 to respect the
  /// server's batch size validation.
  Future<void> flush() async {
    if (_buffer.isEmpty) return;

    final client = http.Client();
    try {
      while (_buffer.isNotEmpty) {
        final chunk = _buffer.length > 100
            ? _buffer.sublist(0, 100)
            : List<FlagEval>.from(_buffer);
        _buffer.removeRange(0, chunk.length);

        final payload = jsonEncode({
          'evaluations': chunk
              .map((e) => e.toJson(gitBranch: gitBranch, version: version))
              .toList(),
        });

        try {
          await client
              .post(_evalUri, headers: _cachedHeaders, body: payload)
              .timeout(_config.timeout);
        } on TimeoutException {
          // Re-queue unsent evaluations and stop trying.
          _buffer.insertAll(0, chunk);
          break;
        } catch (_) {
          _buffer.insertAll(0, chunk);
          break;
        }
      }
    } finally {
      client.close();
    }
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
    _evalUri = Uri.parse('$base/v1/flags/eval');
  }
}
