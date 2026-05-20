import 'dart:math';

import '../otlp/models.dart';
import '../otlp/exporter.dart';

/// Utility for generating random hex trace/span IDs matching OTLP format.
class IdGenerator {
  static final _random = Random.secure();

  /// Generate a 32-character lowercase hex trace ID (16 bytes).
  static String traceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Generate a 16-character lowercase hex span ID (8 bytes).
  static String spanId() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// A single active span that can be finished to emit it.
class ActiveSpan {
  ActiveSpan._({
    required this.traceId,
    required this.spanId,
    required this.name,
    this.parentSpanId,
    required this.exporter,
    this.attributes,
    this.kind,
  });

  final String traceId;
  final String spanId;
  final String name;
  final String? parentSpanId;
  final OtlpExporter exporter;
  final Map<String, Object?>? attributes;
  final int? kind;

  late final String _startNano;
  bool _finished = false;

  final List<OtlpSpanEvent> _events = [];

  void init() {
    _startNano = (DateTime.now().microsecondsSinceEpoch * 1000).toString();
  }

  /// Add a timed event to this span.
  void addEvent(String name, {Map<String, Object?>? attributes}) {
    final nanoTs = (DateTime.now().microsecondsSinceEpoch * 1000).toString();
    _events.add(OtlpSpanEvent(
      timeUnixNano: nanoTs,
      name: name,
      attributes: attributes,
    ));
  }

  /// Set a status on this span.
  void setStatus(OtlpStatus status) {
    _status = status;
  }

  OtlpStatus? _status;

  /// End this span and emit it via the exporter.
  void end() {
    if (_finished) return;
    _finished = true;

    final endNano =
        (DateTime.now().microsecondsSinceEpoch * 1000).toString();

    exporter.emitSpan(OtlpSpan(
      traceId: traceId,
      spanId: spanId,
      parentSpanId: parentSpanId,
      name: name,
      kind: kind,
      startTimeUnixNano: _startNano,
      endTimeUnixNano: endNano,
      attributes: attributes,
      status: _status,
      events: _events.isNotEmpty ? List.unmodifiable(_events) : null,
    ));
  }
}

/// Distributed trace helper that creates spans linked by a shared trace ID.
///
/// Usage:
/// ```dart
/// final trace = SpanTracer(exporter: exporter);
/// final span = trace.startSpan('http_request');
/// // ... do work
/// span.addEvent('cache_miss');
/// span.end();
/// ```
class SpanTracer {
  SpanTracer({
    required OtlpExporter exporter,
    String? traceId,
    this.defaultAttributes,
  })  : _exporter = exporter,
        _traceId = traceId ?? IdGenerator.traceId();

  final OtlpExporter _exporter;
  final String _traceId;
  final Map<String, Object?>? defaultAttributes;

  /// The trace ID used for all spans from this tracer.
  String get traceId => _traceId;

  /// Start a new span under this trace.
  ActiveSpan startSpan(
    String name, {
    String? parentSpanId,
    Map<String, Object?>? attributes,
    int kind = 1, // CLIENT
  }) {
    final mergedAttrs = <String, Object?>{
      ...?defaultAttributes,
      ...?attributes,
    };

    final span = ActiveSpan._(
      traceId: _traceId,
      spanId: IdGenerator.spanId(),
      name: name,
      parentSpanId: parentSpanId,
      exporter: _exporter,
      attributes: mergedAttrs.isNotEmpty ? mergedAttrs : null,
      kind: kind,
    )..init();

    return span;
  }

  /// Convenience: run [action] inside a span, automatically timing it.
  Future<T> withSpan<T>(
    String name,
    Future<T> Function(ActiveSpan span) action, {
    String? parentSpanId,
    Map<String, Object?>? attributes,
    int kind = 1,
  }) async {
    final span = startSpan(name,
        parentSpanId: parentSpanId, attributes: attributes, kind: kind);
    try {
      final result = await action(span);
      span.setStatus(const OtlpStatus(code: 1)); // OK
      return result;
    } catch (e, st) {
      span.setStatus(OtlpStatus(
        code: 2, // ERROR
        message: e.toString(),
      ));
      span.addEvent('exception', attributes: {
        'exception.type': e.runtimeType.toString(),
        'exception.message': e.toString(),
        'exception.stacktrace': st.toString(),
      });
      rethrow;
    } finally {
      span.end();
    }
  }
}
