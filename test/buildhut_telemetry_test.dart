import 'package:flutter_test/flutter_test.dart';
import 'package:buildhut_telemetry/buildhut_telemetry.dart';

void main() {
  group('Severity', () {
    test('maps LogLevel to correct OTLP severity numbers', () {
      expect(LogLevel.trace.severity.number, 1);
      expect(LogLevel.debug.severity.number, 5);
      expect(LogLevel.info.severity.number, 9);
      expect(LogLevel.warn.severity.number, 13);
      expect(LogLevel.error.severity.number, 17);
      expect(LogLevel.fatal.severity.number, 21);
    });
  });

  group('BuildhutExporterConfig', () {
    test('has correct defaults', () {
      const config = BuildhutExporterConfig(
        endpoint: 'https://example.com',
        secret: 'test-secret',
      );

      expect(config.logsPath, '/v1/logs');
      expect(config.tracesPath, '/v1/traces');
      expect(config.metricsPath, '/v1/metrics');
      expect(config.authHeader, 'Authorization');
      expect(config.authScheme, 'Bearer');
      expect(config.flushInterval, const Duration(seconds: 30));
      expect(config.maxBatchSize, 50);
      expect(config.maxBufferSize, 500);
      expect(config.maxRetries, 2);
      expect(config.timeout, const Duration(seconds: 5));
      expect(config.backgroundFlushMultiplier, 4);
      expect(config.circuitBreakerThreshold, 3);
    });
  });

  group('OtlpLogRecord', () {
    test('toJson includes only non-null fields', () {
      final record = OtlpLogRecord(
        timeUnixNano: '123456',
        severityNumber: Severity.info.number,
        severityText: 'INFO',
        body: {'message': 'hello'},
      );

      final json = record.toJson();
      expect(json['timeUnixNano'], '123456');
      expect(json['severityNumber'], 9);
      expect(json['severityText'], 'INFO');
      expect(json['body'], {'message': 'hello'});
      expect(json.containsKey('traceId'), isFalse);
      expect(json.containsKey('spanId'), isFalse);
    });
  });

  group('OtlpMetric', () {
    test('toJson produces valid gauge metric', () {
      final metric = OtlpMetric(
        name: 'test.metric',
        description: 'A test metric',
        unit: 'ms',
        gaugeDataPoints: [
          const OtlpMetricDataPoint(
            timeUnixNano: '999',
            asDouble: 42.5,
          ),
        ],
      );

      final json = metric.toJson();
      expect(json['name'], 'test.metric');
      expect(json['gauge'], isA<Map>());
      expect((json['gauge'] as Map)['dataPoints'], isA<List>());
    });
  });

  group('OtlpSpan', () {
    test('toJson includes required fields', () {
      final span = OtlpSpan(
        traceId: 'abc123',
        spanId: 'def456',
        name: 'test-span',
      );

      final json = span.toJson();
      expect(json['traceId'], 'abc123');
      expect(json['spanId'], 'def456');
      expect(json['name'], 'test-span');
    });
  });

  group('ExportResult', () {
    test('success result string', () {
      const result = ExportResult(success: true, statusCode: 200);
      expect(result.toString(), 'ExportResult(ok)');
    });

    test('failure result includes details', () {
      const result = ExportResult(
        success: false,
        statusCode: 500,
        errorMessage: 'server error',
      );
      expect(result.toString(), contains('500'));
      expect(result.toString(), contains('server error'));
    });
  });

  group('BuildhutLogger', () {
    test('isLoggable respects minimumLevel', () {
      final exporter = OtlpExporter(const BuildhutExporterConfig(
        endpoint: 'https://example.com',
        secret: 'test',
      ));

      final logger = BuildhutLogger(
        exporter: exporter,
        minimumLevel: LogLevel.warn,
      );

      expect(logger.isLoggable(LogLevel.trace), isFalse);
      expect(logger.isLoggable(LogLevel.debug), isFalse);
      expect(logger.isLoggable(LogLevel.info), isFalse);
      expect(logger.isLoggable(LogLevel.warn), isTrue);
      expect(logger.isLoggable(LogLevel.error), isTrue);
      expect(logger.isLoggable(LogLevel.fatal), isTrue);
    });
  });
}
