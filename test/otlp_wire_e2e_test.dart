import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:buildhut_telemetry/buildhut_telemetry.dart';

/// End-to-end wire test: a real loopback HTTP server plays the BuildHut
/// OTLP ingestion surface. The exporter talks to it over actual sockets,
/// and every captured request body is written to /tmp so the payloads the
/// Dart client emits can be replayed against the real buildhut server.
void main() {
  late HttpServer server;
  late String endpoint;
  final captured = <({String path, Map<String, String> headers, String body})>[];

  setUpAll(() async {
    Directory('/tmp/buildhut_telemetry_wire').createSync(recursive: true);
  });

  setUp(() async {
    captured.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      captured.add((
        path: req.uri.path,
        headers: Map<String, String>.from(req.headers.value('authorization') !=
                null
            ? {
                'authorization': req.headers.value('authorization')!,
                if (req.headers.value('x-app-name') != null)
                  'x-app-name': req.headers.value('x-app-name')!,
              }
            : const {}),
        body: body,
      ));
      // Status plan: /v1/logs 200, /v1/traces 200 with partialSuccess,
      // /v1/metrics 401, and any request authenticated as the breaker
      // secret always 401 (used by the circuit-breaker test).
      final auth = req.headers.value('authorization') ?? '';
      if (req.uri.path == '/v1/metrics' ||
          auth == 'Bearer breaker-secret') {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      if (req.uri.path == '/v1/traces') {
        req.response.write(jsonEncode({
          'partialSuccess': {'rejectedSpans': 1, 'errorMessage': 'bad span'},
        }));
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('flush sends logs/traces/metrics envelopes over the wire', () async {
    final exporter = OtlpExporter(BuildhutExporterConfig(
      endpoint: endpoint,
      secret: 'e2e-secret',
      appName: 'wireapp',
      serviceVersion: '1.2.3',
      flushInterval: const Duration(hours: 1), // timer never fires
      retryBaseDelay: const Duration(milliseconds: 1),
      timeout: const Duration(seconds: 2),
    ));

    final logger = BuildhutLogger(exporter: exporter);
    logger.info('hello from e2e', attributes: {'wave': 'test'});
    exporter.emitSpan(OtlpSpan(
      traceId: 'a' * 32,
      spanId: 'b' * 16,
      name: 'op',
      startTimeUnixNano: '1',
      endTimeUnixNano: '2',
    ));
    exporter.emitMetric(OtlpMetric(
      name: 'fps',
      sumDataPoints: [OtlpMetricDataPoint(timeUnixNano: '3', asInt: '58')],
      sumIsMonotonic: false,
    ));

    final results = await exporter.flush();

    // Three sequential POSTs, one per signal.
    expect(captured.map((c) => c.path).toList(),
        ['/v1/logs', '/v1/traces', '/v1/metrics']);

    // Auth + app headers.
    for (final c in captured) {
      expect(c.headers['authorization'], 'Bearer e2e-secret');
      expect(c.headers['x-app-name'], 'wireapp');
    }

    // Logs envelope: map-form resource attributes with service.name.
    final logsEnvelope = jsonDecode(captured[0].body) as Map<String, dynamic>;
    final resourceAttrs = (logsEnvelope['resourceLogs'] as List).first['resource']['attributes'] as Map;
    expect(resourceAttrs['service.name'], 'wireapp');
    expect(resourceAttrs['service.version'], '1.2.3');
    final logRecord = (logsEnvelope['resourceLogs'] as List).first['scopeLogs'][0]['logRecords'][0];
    expect(logRecord['severityNumber'], 9);
    // BuildhutLogger wraps the message in a {message: ...} map body.
    expect(logRecord['body'], {'message': 'hello from e2e'});
    expect(logRecord['attributes']['wave'], 'test');

    // Traces envelope round-trips the span.
    final tracesEnvelope = jsonDecode(captured[1].body) as Map<String, dynamic>;
    final span = (tracesEnvelope['resourceSpans'] as List).first['scopeSpans'][0]['spans'][0];
    expect(span['traceId'], 'a' * 32);
    expect(span['name'], 'op');

    // Metrics envelope carries the sum datapoint.
    final metricsEnvelope = jsonDecode(captured[2].body) as Map<String, dynamic>;
    final metric = (metricsEnvelope['resourceMetrics'] as List).first['scopeMetrics'][0]['metrics'][0];
    expect(metric['name'], 'fps');
    expect(metric['sum']['dataPoints'][0]['asInt'], '58');

    // ExportResults reflect each server branch.
    expect(results[0].success, isTrue);
    expect(results[0].statusCode, 200);
    expect(results[1].success, isTrue); // partialSuccess is still success
    expect(results[1].rejectedCount, 1);
    expect(results[1].errorMessage, 'bad span');
    expect(results[2].success, isFalse); // 401
    expect(results[2].statusCode, 401);

    // Persist captured payloads for server-side replay.
    for (final c in captured) {
      final name = c.path.split('/').last;
      File('/tmp/buildhut_telemetry_wire/$name.json').writeAsStringSync(c.body);
    }
    File('/tmp/buildhut_telemetry_wire/meta.json').writeAsStringSync(
        jsonEncode({'secret': 'e2e-secret', 'appName': 'wireapp'}));
  });

  test('circuit breaker opens after threshold and drops records', () async {
    // The breaker test needs /v1/logs itself to fail — same mock server,
    // but authenticating with a secret the handler always rejects.
    final exporter = OtlpExporter(BuildhutExporterConfig(
      endpoint: endpoint,
      secret: 'breaker-secret',
      flushInterval: const Duration(hours: 1),
      retryBaseDelay: const Duration(milliseconds: 1),
      maxRetries: 0,
      timeout: const Duration(seconds: 2),
      circuitBreakerThreshold: 3,
    ));

    // /v1/logs always answers 401 → three failed flushes open the breaker.
    exporter.emitLog(OtlpLogRecord(body: 'one')..severityNumber = 9);
    expect((await exporter.flush()).first.success, isFalse);
    exporter.emitLog(OtlpLogRecord(body: 'two')..severityNumber = 9);
    expect((await exporter.flush()).first.success, isFalse);
    exporter.emitLog(OtlpLogRecord(body: 'three')..severityNumber = 9);
    expect((await exporter.flush()).first.success, isFalse);
    expect(captured.length, 3);

    // Breaker open: emit is dropped before the socket, flush is a no-op.
    exporter.emitLog(OtlpLogRecord(body: 'dropped')..severityNumber = 9);
    final results = await exporter.flush();
    expect(results, isEmpty);
    expect(captured.length, 3);
  });

  test('401 never retries, 500 retries then fails', () async {
    var attempts = 0;
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      attempts++;
      await utf8.decoder.bind(req).join();
      req.response.statusCode = attempts <= 2 ? 500 : 200;
      await req.response.close();
    });

    final exporter = OtlpExporter(BuildhutExporterConfig(
      endpoint: endpoint,
      secret: 's',
      flushInterval: const Duration(hours: 1),
      retryBaseDelay: const Duration(milliseconds: 1),
      maxRetries: 2,
      timeout: const Duration(seconds: 2),
    ));
    exporter.emitLog(OtlpLogRecord(body: 'x')..severityNumber = 9);
    final results = await exporter.flush();
    expect(results.first.success, isTrue);
    expect(attempts, 3); // 500, 500, then success
  });
}
