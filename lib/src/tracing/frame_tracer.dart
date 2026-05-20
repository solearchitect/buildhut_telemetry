import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../otlp/models.dart';
import '../otlp/exporter.dart';

/// Snapshot of frame-rate statistics at a point in time.
class FpsSnapshot {
  const FpsSnapshot({
    required this.timestamp,
    required this.fps,
    required this.averageFrameTimeMs,
    required this.maxFrameTimeMs,
    required this.jankFrames,
    required this.totalFrames,
    required this.missedVsyncFrames,
  });

  /// Unix epoch nanoseconds.
  final String timestamp;

  /// Frames per second (computed over the reporting window).
  final double fps;

  /// Average frame build time in milliseconds.
  final double averageFrameTimeMs;

  /// Max frame build time in milliseconds.
  final double maxFrameTimeMs;

  /// Number of frames that exceeded 16ms (jank).
  final int jankFrames;

  /// Total frames observed in this window.
  final int totalFrames;

  /// Frames that missed vsync (>32ms).
  final int missedVsyncFrames;

  @override
  String toString() =>
      'FpsSnapshot(fps=$fps, avg=${averageFrameTimeMs}ms, '
      'max=${maxFrameTimeMs}ms, jank=$jankFrames, '
      'missedVsync=$missedVsyncFrames, total=$totalFrames)';
}

/// Callback invoked when an FPS snapshot is ready.
typedef FpsSnapshotCallback = void Function(FpsSnapshot snapshot);

/// Frame-rate performance tracer that measures Flutter frame times
/// and reports them as OTLP metrics to BuildHut.
///
/// Uses [SchedulerBinding.instance.addTimingsCallback] to get accurate
/// frame build/rasterization times directly from the engine.
///
/// Usage:
/// ```dart
/// final tracer = FrameRateTracer(exporter: exporter)
///   ..onSnapshot = (snap) => print(snap);
/// tracer.start();
/// // ... later
/// tracer.stop();
/// ```
class FrameRateTracer {
  FrameRateTracer({
    required OtlpExporter exporter,
    this.reportingInterval = const Duration(seconds: 5),
    this.jankThresholdMs = 16.0,
    this.missedVsyncThresholdMs = 32.0,
    this.reportAsMetrics = true,
    this.reportAsLogOnJank = true,
  }) : _exporter = exporter;

  final OtlpExporter _exporter;

  /// How often to emit an [FpsSnapshot].
  final Duration reportingInterval;

  /// Frame time above this is counted as jank (default 16ms for 60fps).
  final double jankThresholdMs;

  /// Frame time above this is counted as missed vsync (default 32ms).
  final double missedVsyncThresholdMs;

  /// Whether to push fps metrics via OTLP metrics.
  final bool reportAsMetrics;

  /// Whether to emit a warning log when jank is detected.
  final bool reportAsLogOnJank;

  /// Optional callback for real-time snapshot observation.
  FpsSnapshotCallback? onSnapshot;

  Timer? _reportTimer;
  bool _running = false;

  // Accumulators for the current reporting window.
  int _frameCount = 0;
  int _jankFrames = 0;
  int _missedVsyncFrames = 0;
  double _totalFrameTimeMs = 0;
  double _maxFrameTimeMs = 0;

  // ---- Lifecycle -----------------------------------------------------------

  /// Start tracking frame timing.
  void start() {
    if (_running) return;
    _running = true;
    _resetWindow();

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _reportTimer = Timer.periodic(reportingInterval, (_) => _emitSnapshot());
  }

  /// Stop tracking and flush final snapshot.
  void stop() {
    if (!_running) return;
    _running = false;

    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _reportTimer?.cancel();
    _reportTimer = null;

    if (_frameCount > 0) {
      _emitSnapshot();
    }
  }

  /// Whether the tracer is currently active.
  bool get isRunning => _running;

  // ---- Frame callback ------------------------------------------------------

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      // Use totalSpan as the effective frame time (end-to-end latency
      // from vsync start to raster finish).
      final frameTimeMs = t.totalSpan.inMicroseconds / 1000.0;

      _frameCount++;
      _totalFrameTimeMs += frameTimeMs;
      if (frameTimeMs > _maxFrameTimeMs) {
        _maxFrameTimeMs = frameTimeMs;
      }
      if (frameTimeMs > jankThresholdMs) _jankFrames++;
      if (frameTimeMs > missedVsyncThresholdMs) _missedVsyncFrames++;
    }
  }

  // ---- Reporting -----------------------------------------------------------

  void _emitSnapshot() {
    if (_frameCount == 0) return;

    final now = DateTime.now();
    final timestamp = (now.microsecondsSinceEpoch * 1000).toString();

    final windowSeconds = reportingInterval.inMilliseconds / 1000.0;
    final fps = _frameCount / windowSeconds;
    final avgFrameTime = _totalFrameTimeMs / _frameCount;

    final snapshot = FpsSnapshot(
      timestamp: timestamp,
      fps: fps,
      averageFrameTimeMs: avgFrameTime,
      maxFrameTimeMs: _maxFrameTimeMs,
      jankFrames: _jankFrames,
      totalFrames: _frameCount,
      missedVsyncFrames: _missedVsyncFrames,
    );

    onSnapshot?.call(snapshot);

    if (reportAsMetrics) {
      _pushMetrics(snapshot);
    }

    if (reportAsLogOnJank && _jankFrames > 0) {
      _pushJankLog(snapshot);
    }

    _resetWindow();
  }

  void _pushMetrics(FpsSnapshot snap) {
    final ts = snap.timestamp;

    // Each metric is a separate OtlpMetric in the same metrics buffer,
    // so they all get batched into a single HTTP POST on flush.
    _exporter.emitMetric(OtlpMetric(
      name: 'app.fps',
      description: 'Frames per second',
      unit: 'fps',
      gaugeDataPoints: [
        OtlpMetricDataPoint(timeUnixNano: ts, asDouble: snap.fps),
      ],
    ));
    _exporter.emitMetric(OtlpMetric(
      name: 'app.frame.time.avg_ms',
      description: 'Average frame time in milliseconds',
      unit: 'ms',
      gaugeDataPoints: [
        OtlpMetricDataPoint(
          timeUnixNano: ts,
          asDouble: snap.averageFrameTimeMs,
        ),
      ],
    ));
    _exporter.emitMetric(OtlpMetric(
      name: 'app.frame.time.max_ms',
      description: 'Max frame time in milliseconds',
      unit: 'ms',
      gaugeDataPoints: [
        OtlpMetricDataPoint(
          timeUnixNano: ts,
          asDouble: snap.maxFrameTimeMs,
        ),
      ],
    ));
    _exporter.emitMetric(OtlpMetric(
      name: 'app.frame.jank_count',
      description: 'Number of janky frames in window',
      unit: '1',
      sumDataPoints: [
        OtlpMetricDataPoint(
            timeUnixNano: ts, asDouble: snap.jankFrames.toDouble()),
      ],
      sumIsMonotonic: true,
      sumAggregationTemporality: 2, // CUMULATIVE
    ));
    _exporter.emitMetric(OtlpMetric(
      name: 'app.frame.missed_vsync',
      description: 'Number of frames that missed vsync',
      unit: '1',
      sumDataPoints: [
        OtlpMetricDataPoint(
          timeUnixNano: ts,
          asDouble: snap.missedVsyncFrames.toDouble(),
        ),
      ],
      sumIsMonotonic: true,
      sumAggregationTemporality: 2,
    ));
  }

  void _pushJankLog(FpsSnapshot snap) {
    _exporter.emitLog(OtlpLogRecord(
      timeUnixNano: snap.timestamp,
      severityNumber: Severity.warn.number,
      severityText: Severity.warn.text,
      body: {
        'message': 'Frame jank detected',
        'fps': snap.fps,
        'avgFrameTimeMs': snap.averageFrameTimeMs,
        'maxFrameTimeMs': snap.maxFrameTimeMs,
        'jankFrames': snap.jankFrames,
        'missedVsyncFrames': snap.missedVsyncFrames,
        'totalFrames': snap.totalFrames,
      },
      attributes: {
        'telemetry.type': 'performance',
        'jank.threshold_ms': jankThresholdMs,
      },
    ));
  }

  void _resetWindow() {
    _frameCount = 0;
    _jankFrames = 0;
    _missedVsyncFrames = 0;
    _totalFrameTimeMs = 0;
    _maxFrameTimeMs = 0;
  }
}
