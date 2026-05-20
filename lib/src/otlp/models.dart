/// OTLP (OpenTelemetry Protocol) data models matching the BuildHut API schema.
///
/// These models produce JSON payloads that conform to the Zod schemas defined
/// in the BuildHut server's `otlp/schemas.ts`.
library;

/// Severity levels matching OpenTelemetry log severity numbers.
enum Severity {
  trace(1, 'TRACE'),
  trace2(2, 'TRACE2'),
  trace3(3, 'TRACE3'),
  trace4(4, 'TRACE4'),
  debug(5, 'DEBUG'),
  debug2(6, 'DEBUG2'),
  debug3(7, 'DEBUG3'),
  debug4(8, 'DEBUG4'),
  info(9, 'INFO'),
  info2(10, 'INFO2'),
  info3(11, 'INFO3'),
  info4(12, 'INFO4'),
  warn(13, 'WARN'),
  warn2(14, 'WARN2'),
  warn3(15, 'WARN3'),
  warn4(16, 'WARN4'),
  error(17, 'ERROR'),
  error2(18, 'ERROR2'),
  error3(19, 'ERROR3'),
  error4(20, 'ERROR4'),
  fatal(21, 'FATAL'),
  fatal2(22, 'FATAL2'),
  fatal3(23, 'FATAL3'),
  fatal4(24, 'FATAL4');

  const Severity(this.number, this.text);
  final int number;
  final String text;
}

/// A key-value attribute following the OTLP AnyValue convention.
class OtlpAttribute {
  const OtlpAttribute(this.key, this.value);

  final String key;
  final Object? value;

  MapEntry<String, Object?> toMapEntry() => MapEntry(key, value);
}

/// An OTLP Log Record.
class OtlpLogRecord {
  OtlpLogRecord({
    this.timeUnixNano,
    this.observedTimeUnixNano,
    this.severityNumber,
    this.severityText,
    this.body,
    this.attributes,
    this.droppedAttributesCount,
    this.flags,
    this.traceId,
    this.spanId,
  });

  /// Time when the event occurred as Unix nanoseconds string.
  String? timeUnixNano;

  /// Time when the event was observed as Unix nanoseconds string.
  String? observedTimeUnixNano;

  /// Numerical severity (1-24), see [Severity].
  int? severityNumber;

  /// Text representation of severity.
  String? severityText;

  /// Log body — any value (string, number, map, etc.).
  Object? body;

  /// Additional attributes.
  Map<String, Object?>? attributes;

  int? droppedAttributesCount;
  int? flags;

  /// Hex-encoded trace ID.
  String? traceId;

  /// Hex-encoded span ID.
  String? spanId;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (timeUnixNano != null) json['timeUnixNano'] = timeUnixNano;
    if (observedTimeUnixNano != null) {
      json['observedTimeUnixNano'] = observedTimeUnixNano;
    }
    if (severityNumber != null) json['severityNumber'] = severityNumber;
    if (severityText != null) json['severityText'] = severityText;
    if (body != null) json['body'] = body;
    if (attributes != null) json['attributes'] = attributes;
    if (droppedAttributesCount != null) {
      json['droppedAttributesCount'] = droppedAttributesCount;
    }
    if (flags != null) json['flags'] = flags;
    if (traceId != null) json['traceId'] = traceId;
    if (spanId != null) json['spanId'] = spanId;
    return json;
  }
}

/// An OTLP Span for traces.
class OtlpSpan {
  OtlpSpan({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    required this.name,
    this.kind,
    this.startTimeUnixNano,
    this.endTimeUnixNano,
    this.attributes,
    this.status,
    this.events,
    this.links,
    this.flags,
  });

  String traceId;
  String spanId;
  String? parentSpanId;
  String name;
  int? kind;
  String? startTimeUnixNano;
  String? endTimeUnixNano;
  Map<String, Object?>? attributes;
  OtlpStatus? status;
  List<OtlpSpanEvent>? events;
  List<OtlpSpanLink>? links;
  int? flags;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'traceId': traceId,
      'spanId': spanId,
      'name': name,
    };
    if (parentSpanId != null) json['parentSpanId'] = parentSpanId;
    if (kind != null) json['kind'] = kind;
    if (startTimeUnixNano != null) {
      json['startTimeUnixNano'] = startTimeUnixNano;
    }
    if (endTimeUnixNano != null) json['endTimeUnixNano'] = endTimeUnixNano;
    if (attributes != null) json['attributes'] = attributes;
    if (status != null) json['status'] = status!.toJson();
    if (events != null) {
      json['events'] = events!.map((e) => e.toJson()).toList();
    }
    if (links != null) {
      json['links'] = links!.map((l) => l.toJson()).toList();
    }
    if (flags != null) json['flags'] = flags;
    return json;
  }
}

class OtlpStatus {
  const OtlpStatus({this.message, this.code});

  final String? message;
  final int? code;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (message != null) json['message'] = message;
    if (code != null) json['code'] = code;
    return json;
  }
}

class OtlpSpanEvent {
  OtlpSpanEvent({
    this.timeUnixNano,
    this.name,
    this.attributes,
  });

  String? timeUnixNano;
  String? name;
  Map<String, Object?>? attributes;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (timeUnixNano != null) json['timeUnixNano'] = timeUnixNano;
    if (name != null) json['name'] = name;
    if (attributes != null) json['attributes'] = attributes;
    return json;
  }
}

class OtlpSpanLink {
  const OtlpSpanLink({this.traceId, this.spanId, this.attributes});

  final String? traceId;
  final String? spanId;
  final Map<String, Object?>? attributes;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (traceId != null) json['traceId'] = traceId;
    if (spanId != null) json['spanId'] = spanId;
    if (attributes != null) json['attributes'] = attributes;
    return json;
  }
}

/// OTLP Metric data point for gauge/sum types.
class OtlpMetricDataPoint {
  const OtlpMetricDataPoint({
    this.startTimeUnixNano,
    required this.timeUnixNano,
    this.asDouble,
    this.asInt,
    this.attributes,
    this.flags,
  });

  final String? startTimeUnixNano;
  final String timeUnixNano;
  final double? asDouble;
  final String? asInt;
  final Map<String, Object?>? attributes;
  final int? flags;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{'timeUnixNano': timeUnixNano};
    if (startTimeUnixNano != null) {
      json['startTimeUnixNano'] = startTimeUnixNano;
    }
    if (asDouble != null) json['asDouble'] = asDouble;
    if (asInt != null) json['asInt'] = asInt;
    if (attributes != null) json['attributes'] = attributes;
    if (flags != null) json['flags'] = flags;
    return json;
  }
}

/// An OTLP Metric.
class OtlpMetric {
  OtlpMetric({
    required this.name,
    this.description,
    this.unit,
    this.gaugeDataPoints,
    this.sumDataPoints,
    this.sumAggregationTemporality,
    this.sumIsMonotonic,
  });

  String name;
  String? description;
  String? unit;

  /// Gauge data points.
  List<OtlpMetricDataPoint>? gaugeDataPoints;

  /// Sum data points.
  List<OtlpMetricDataPoint>? sumDataPoints;
  int? sumAggregationTemporality;
  bool? sumIsMonotonic;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{'name': name};
    if (description != null) json['description'] = description;
    if (unit != null) json['unit'] = unit;
    if (gaugeDataPoints != null) {
      json['gauge'] = {
        'dataPoints': gaugeDataPoints!.map((dp) => dp.toJson()).toList(),
      };
    }
    if (sumDataPoints != null) {
      final sumJson = <String, Object?>{
        'dataPoints': sumDataPoints!.map((dp) => dp.toJson()).toList(),
      };
      if (sumAggregationTemporality != null) {
        sumJson['aggregationTemporality'] = sumAggregationTemporality;
      }
      if (sumIsMonotonic != null) sumJson['isMonotonic'] = sumIsMonotonic;
      json['sum'] = sumJson;
    }
    return json;
  }
}

// ---------------------------------------------------------------------------
// Full OTLP export request envelopes
// ---------------------------------------------------------------------------

/// Builds a complete `ExportLogsServiceRequest` JSON envelope.
Map<String, Object?> buildLogsExportRequest({
  required String serviceName,
  String? serviceVersion,
  Map<String, Object?>? resourceAttributes,
  required List<OtlpLogRecord> logRecords,
  String? scopeName,
  String? scopeVersion,
}) {
  return {
    'resourceLogs': [
      {
        'resource': {
          'attributes': {
            'service.name': serviceName,
            if (serviceVersion != null) 'service.version': serviceVersion,
            ...?resourceAttributes,
          },
        },
        'scopeLogs': [
          {
            if (scopeName != null || scopeVersion != null)
              'scope': {
                if (scopeName != null) 'name': scopeName,
                if (scopeVersion != null) 'version': scopeVersion,
              },
            'logRecords': logRecords.map((r) => r.toJson()).toList(),
          },
        ],
      },
    ],
  };
}

/// Builds a complete `ExportTraceServiceRequest` JSON envelope.
Map<String, Object?> buildTracesExportRequest({
  required String serviceName,
  String? serviceVersion,
  Map<String, Object?>? resourceAttributes,
  required List<OtlpSpan> spans,
  String? scopeName,
  String? scopeVersion,
}) {
  return {
    'resourceSpans': [
      {
        'resource': {
          'attributes': {
            'service.name': serviceName,
            if (serviceVersion != null) 'service.version': serviceVersion,
            ...?resourceAttributes,
          },
        },
        'scopeSpans': [
          {
            if (scopeName != null || scopeVersion != null)
              'scope': {
                if (scopeName != null) 'name': scopeName,
                if (scopeVersion != null) 'version': scopeVersion,
              },
            'spans': spans.map((s) => s.toJson()).toList(),
          },
        ],
      },
    ],
  };
}

/// Builds a complete `ExportMetricsServiceRequest` JSON envelope.
Map<String, Object?> buildMetricsExportRequest({
  required String serviceName,
  String? serviceVersion,
  Map<String, Object?>? resourceAttributes,
  required List<OtlpMetric> metrics,
  String? scopeName,
  String? scopeVersion,
}) {
  return {
    'resourceMetrics': [
      {
        'resource': {
          'attributes': {
            'service.name': serviceName,
            if (serviceVersion != null) 'service.version': serviceVersion,
            ...?resourceAttributes,
          },
        },
        'scopeMetrics': [
          {
            if (scopeName != null || scopeVersion != null)
              'scope': {
                if (scopeName != null) 'name': scopeName,
                if (scopeVersion != null) 'version': scopeVersion,
              },
            'metrics': metrics.map((m) => m.toJson()).toList(),
          },
        ],
      },
    ],
  };
}
