// Runs the FFT acoustic pipeline on a background isolate so analysis never blocks the audio-capture path.
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/acoustic_detection.dart';
import 'acoustic/acoustic_pipeline.dart';

/// Runs the FFT [AcousticPipeline] on a background isolate so the audio capture
/// path never blocks on analysis. The main isolate slices the decimated mono
/// stream into frames ([FrameSlicer]) and ships them over; detections come back
/// on [detections].
///
/// Lifecycle mirrors the other services: [start] once per capture session,
/// [addMonoSamples] as audio flows, [flush] when the analysis gate closes, then
/// [stop]/[dispose].
class AcousticAnalyzer {
  AcousticAnalyzer();

  final StreamController<AcousticDetection> _detections =
      StreamController<AcousticDetection>.broadcast();

  Isolate? _isolate;
  SendPort? _commandPort;
  ReceivePort? _receivePort;
  FrameSlicer? _slicer;
  Future<void>? _starting;
  bool _disposed = false;

  /// Frames sent to the isolate but not yet acknowledged. Bounds the cross-port
  /// queue so a stalled/slow isolate can never grow memory without limit — under
  /// backlog we drop frames (the detectors tolerate gaps) instead of buffering.
  int _outstanding = 0;
  int _droppedFrames = 0;
  static const int _maxOutstanding = 64; // ~4 s of 16 kHz / 1024-hop frames

  Stream<AcousticDetection> get detections => _detections.stream;

  bool get isRunning => _commandPort != null;

  /// Total frames dropped due to backpressure since the last [start]. Surfaced
  /// for diagnostics.
  int get droppedFrames => _droppedFrames;

  Future<void> start({
    required int sampleRate,
    required int fftSize,
    required AcousticDetectorFlags flags,
    String captureSessionId = '',
  }) async {
    if (_disposed || !flags.any) {
      return;
    }
    await stop();
    _outstanding = 0;
    _droppedFrames = 0;
    _slicer = FrameSlicer(fftSize: fftSize, sampleRate: sampleRate);
    final ready = Completer<SendPort>();
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    receivePort.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is! List || message.isEmpty) {
        return;
      }
      switch (message[0]) {
        case 'result':
          // One frame finished (with or without detections); free a slot.
          if (_outstanding > 0) {
            _outstanding -= 1;
          }
          _emitRows(message[1] as List);
          break;
        case 'detections':
          // Flush-time detections, not tied to an outstanding frame.
          _emitRows(message[1] as List);
          break;
      }
    });
    final starting =
        Isolate.spawn(_analyzerEntryPoint, {
          'reply': receivePort.sendPort,
          'fftSize': fftSize,
          'sampleRate': sampleRate,
          'flags': flags.toMap(),
          'captureSessionId': captureSessionId,
        }).then((isolate) async {
          _isolate = isolate;
          _commandPort = await ready.future;
        });
    _starting = starting;
    await starting;
  }

  /// Slices [samples] (mono, normalized -1..1, at the analyzer sample rate)
  /// starting at [chunkStartUtc] into frames and dispatches them to the isolate.
  void addMonoSamples(Float64List samples, DateTime chunkStartUtc) {
    final port = _commandPort;
    final slicer = _slicer;
    if (port == null || slicer == null || samples.isEmpty) {
      return;
    }
    for (final framed in slicer.add(samples, chunkStartUtc)) {
      if (_outstanding >= _maxOutstanding) {
        // Isolate is behind; drop this frame rather than grow the queue. The
        // slicer has already advanced, so later frames keep correct timestamps.
        _droppedFrames += 1;
        continue;
      }
      _outstanding += 1;
      port.send([
        'frame',
        framed.frame,
        framed.atUtc.toUtc().microsecondsSinceEpoch,
      ]);
    }
  }

  void _emitRows(List rows) {
    for (final row in rows) {
      if (_detections.isClosed) {
        break;
      }
      _detections.add(
        AcousticDetection.fromJson((row as Map).cast<String, dynamic>()),
      );
    }
  }

  /// Drops any buffered partial frame so the frame timeline re-anchors to the
  /// next chunk. Call when feeding resumes after a gap (the loudness gate
  /// reopening), so frames are not mis-timestamped against a stale anchor.
  void resyncFeed() {
    _slicer?.reset();
  }

  /// Asks the isolate to close any open episode (e.g. when the loudness gate
  /// closes); resulting detections arrive on [detections].
  void flush() {
    _commandPort?.send(const ['flush']);
  }

  Future<void> stop() async {
    final starting = _starting;
    if (starting != null) {
      await starting;
    }
    _commandPort?.send(const ['stop']);
    _commandPort = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _slicer?.reset();
    _slicer = null;
    _starting = null;
    _outstanding = 0;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _detections.close();
  }
}

/// Isolate entry point. Owns the [AcousticPipeline] and its detector state for
/// the lifetime of one capture session.
void _analyzerEntryPoint(Map<String, dynamic> args) {
  final reply = args['reply'] as SendPort;
  final pipeline = AcousticPipeline(
    fftSize: args['fftSize'] as int,
    sampleRate: args['sampleRate'] as int,
    flags: AcousticDetectorFlags.fromMap(args['flags'] as Map),
    captureSessionId: args['captureSessionId'] as String? ?? '',
  );
  final commandPort = ReceivePort();
  reply.send(commandPort.sendPort);
  commandPort.listen((message) {
    if (message is! List || message.isEmpty) {
      return;
    }
    switch (message[0]) {
      case 'frame':
        var rows = const <Map<String, dynamic>>[];
        try {
          final frame = message[1] as Float64List;
          final atUtc = DateTime.fromMicrosecondsSinceEpoch(
            message[2] as int,
            isUtc: true,
          );
          rows = pipeline.process(frame, atUtc).map((d) => d.toJson()).toList();
        } catch (_) {
          // One bad frame must not kill the analysis loop; skip it.
          rows = const [];
        }
        // Always reply so the main isolate's backpressure counter is balanced,
        // even when a frame produced nothing or threw.
        reply.send(['result', rows]);
        break;
      case 'flush':
        try {
          final detections = pipeline.flush();
          if (detections.isNotEmpty) {
            reply.send([
              'detections',
              detections.map((d) => d.toJson()).toList(),
            ]);
          }
        } catch (_) {
          // Ignore; nothing to flush.
        }
        break;
      case 'stop':
        commandPort.close();
        break;
    }
  });
}
