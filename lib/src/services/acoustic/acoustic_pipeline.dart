import 'dart:typed_data';

import '../../models/acoustic_detection.dart';
import 'music_detector.dart';
import 'sleep_cycle_detector.dart';
import 'snore_detector.dart';
import 'speech_detector.dart';
import 'spectral_features.dart';

/// Which detectors the pipeline should run. Toggled from [AppConfig].
class AcousticDetectorFlags {
  const AcousticDetectorFlags({
    this.snore = true,
    this.music = true,
    this.speech = true,
    this.sleep = false,
  });

  final bool snore;
  final bool music;
  final bool speech;

  /// Sleep-cycle analysis. Off by default; turned on for a sleep session. The
  /// sleep detector consumes the snore detector's output, so [snore] is forced
  /// on internally whenever [sleep] is set.
  final bool sleep;

  bool get any => snore || music || speech || sleep;

  Map<String, dynamic> toMap() =>
      {'snore': snore, 'music': music, 'speech': speech, 'sleep': sleep};

  factory AcousticDetectorFlags.fromMap(Map<dynamic, dynamic> map) {
    return AcousticDetectorFlags(
      snore: map['snore'] as bool? ?? true,
      music: map['music'] as bool? ?? true,
      speech: map['speech'] as bool? ?? true,
      sleep: map['sleep'] as bool? ?? false,
    );
  }
}

/// Synchronous analysis core: FFT feature extraction + the enabled detectors.
/// Holds detector state across frames, so feed frames in capture order. Used by
/// both [AcousticAnalyzer] (inside an isolate) and unit/integration tests
/// (directly, no isolate).
class AcousticPipeline {
  AcousticPipeline({
    required this.fftSize,
    required this.sampleRate,
    AcousticDetectorFlags flags = const AcousticDetectorFlags(),
    String captureSessionId = '',
  })  : _analyzer = SpectralAnalyzer(fftSize: fftSize, sampleRate: sampleRate),
        // The sleep detector needs snore events, so enable snore whenever sleep
        // is on even if the snore flag itself is off.
        _snore = (flags.snore || flags.sleep)
            ? SnoreDetector(
                frameSeconds: (fftSize ~/ 2) / sampleRate,
                captureSessionId: captureSessionId,
              )
            : null,
        _sleep = flags.sleep
            ? SleepCycleDetector(
                frameSeconds: (fftSize ~/ 2) / sampleRate,
                captureSessionId: captureSessionId,
              )
            : null,
        _emitSnore = flags.snore,
        _music = flags.music
            ? MusicDetector(
                frameSeconds: (fftSize ~/ 2) / sampleRate,
                captureSessionId: captureSessionId,
              )
            : null,
        _speech = flags.speech
            ? SpeechDetector(
                frameSeconds: (fftSize ~/ 2) / sampleRate,
                captureSessionId: captureSessionId,
              )
            : null;

  final int fftSize;
  final int sampleRate;
  final SpectralAnalyzer _analyzer;
  final SnoreDetector? _snore;
  final SleepCycleDetector? _sleep;

  /// Whether snore detections should be surfaced. False when snore is only
  /// running internally to feed the sleep detector.
  final bool _emitSnore;
  final MusicDetector? _music;
  final SpeechDetector? _speech;

  /// Runs one frame ([fftSize] normalized mono samples) through every enabled
  /// detector and returns whatever they emit.
  List<AcousticDetection> process(Float64List frame, DateTime atUtc) {
    final features = _analyzer.analyze(frame);
    final out = <AcousticDetection>[];
    final snore = _snore;
    final sleep = _sleep;
    final music = _music;
    final speech = _speech;
    // Run snore first; the sleep detector consumes its episodes for this frame.
    final snoreEvents =
        snore != null ? snore.add(features, atUtc) : const <AcousticDetection>[];
    if (_emitSnore) {
      out.addAll(snoreEvents);
    }
    if (sleep != null) {
      out.addAll(sleep.add(features, atUtc, snoreEvents));
    }
    if (music != null) {
      out.addAll(music.add(features, atUtc));
    }
    if (speech != null) {
      out.addAll(speech.add(features, atUtc));
    }
    return out;
  }

  /// Closes any open snore episode and flushes the in-progress sleep epoch. Call
  /// when the analysis gate closes.
  List<AcousticDetection> flush() {
    final out = <AcousticDetection>[];
    final snoreFlush = _snore?.flush() ?? const <AcousticDetection>[];
    if (_emitSnore) {
      out.addAll(snoreFlush);
    }
    final sleep = _sleep;
    if (sleep != null) {
      // Feed the snore detector's flushed episodes into the sleep epoch too.
      out.addAll(sleep.flush());
    }
    return out;
  }
}

/// Slices a continuous mono sample stream into fixed [fftSize] frames with 50%
/// overlap (hop = fftSize/2), assigning each frame the UTC time of its final
/// sample. Tolerant of variable-length input chunks. Reset between capture
/// sessions (or after a gap) so the time anchor stays accurate.
class FrameSlicer {
  FrameSlicer({required this.fftSize, required this.sampleRate})
      : _hop = fftSize ~/ 2;

  final int fftSize;
  final int sampleRate;
  final int _hop;

  final List<double> _buffer = [];
  DateTime? _anchorUtc; // UTC time of _buffer[0]

  /// Appends [samples] (mono, normalized) starting at [chunkStartUtc] and
  /// returns the complete frames now available, each paired with its end time.
  List<({Float64List frame, DateTime atUtc})> add(
    Float64List samples,
    DateTime chunkStartUtc,
  ) {
    if (_buffer.isEmpty) {
      _anchorUtc = chunkStartUtc;
    }
    _buffer.addAll(samples);
    final out = <({Float64List frame, DateTime atUtc})>[];
    while (_buffer.length >= fftSize) {
      final frame = Float64List(fftSize);
      for (var i = 0; i < fftSize; i++) {
        frame[i] = _buffer[i];
      }
      final anchor = _anchorUtc!;
      final endUtc = anchor.add(
        Duration(microseconds: (fftSize * 1e6 / sampleRate).round()),
      );
      out.add((frame: frame, atUtc: endUtc));
      _buffer.removeRange(0, _hop);
      _anchorUtc = anchor.add(
        Duration(microseconds: (_hop * 1e6 / sampleRate).round()),
      );
    }
    return out;
  }

  void reset() {
    _buffer.clear();
    _anchorUtc = null;
  }
}
