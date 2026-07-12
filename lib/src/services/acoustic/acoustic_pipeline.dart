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
    this.sleep = false,
    this.sleepCycleAlarms = false,
    this.sleepCycleMinutesByIndex = const [],
    this.sleepMotionSignal = false,
    this.sleepAmbientLightSignal = false,
    this.sleepPhoneContextSignal = false,
    this.music = true,
    this.speech = true,
  });

  final bool snore;
  final bool sleep;
  final bool sleepCycleAlarms;
  final List<double> sleepCycleMinutesByIndex;
  final bool sleepMotionSignal;
  final bool sleepAmbientLightSignal;
  final bool sleepPhoneContextSignal;
  final bool music;
  final bool speech;

  bool get any => snore || sleep || music || speech;

  Map<String, dynamic> toMap() => {
    'snore': snore,
    'sleep': sleep,
    'sleepCycleAlarms': sleepCycleAlarms,
    'sleepCycleMinutesByIndex': sleepCycleMinutesByIndex,
    'sleepMotionSignal': sleepMotionSignal,
    'sleepAmbientLightSignal': sleepAmbientLightSignal,
    'sleepPhoneContextSignal': sleepPhoneContextSignal,
    'music': music,
    'speech': speech,
  };

  factory AcousticDetectorFlags.fromMap(Map<dynamic, dynamic> map) {
    return AcousticDetectorFlags(
      snore: map['snore'] as bool? ?? true,
      sleep: map['sleep'] as bool? ?? false,
      sleepCycleAlarms: map['sleepCycleAlarms'] as bool? ?? false,
      sleepCycleMinutesByIndex: _asDoubleList(map['sleepCycleMinutesByIndex']),
      sleepMotionSignal: map['sleepMotionSignal'] as bool? ?? false,
      sleepAmbientLightSignal: map['sleepAmbientLightSignal'] as bool? ?? false,
      sleepPhoneContextSignal: map['sleepPhoneContextSignal'] as bool? ?? false,
      music: map['music'] as bool? ?? true,
      speech: map['speech'] as bool? ?? true,
    );
  }

  static List<double> _asDoubleList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .map((entry) {
          if (entry is num) {
            return entry.toDouble();
          }
          return double.tryParse(entry.toString()) ?? 90.0;
        })
        .where((entry) => entry.isFinite)
        .toList(growable: false);
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
  }) : _analyzer = SpectralAnalyzer(fftSize: fftSize, sampleRate: sampleRate),
       _snore = flags.snore
           ? SnoreDetector(
               frameSeconds: (fftSize ~/ 2) / sampleRate,
               captureSessionId: captureSessionId,
             )
           : null,
       _sleep = flags.sleep
           ? SleepCycleDetector(
               frameSeconds: (fftSize ~/ 2) / sampleRate,
               captureSessionId: captureSessionId,
               config: SleepCycleConfig(
                 cycleMinutesByIndex: flags.sleepCycleMinutesByIndex,
                 alarmsEnabled: flags.sleepCycleAlarms,
                 motionSignalEnabled: flags.sleepMotionSignal,
                 ambientLightSignalEnabled: flags.sleepAmbientLightSignal,
                 phoneContextSignalEnabled: flags.sleepPhoneContextSignal,
               ),
             )
           : null,
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
    if (snore != null) {
      out.addAll(snore.add(features, atUtc));
    }
    if (sleep != null) {
      out.addAll(sleep.add(features, atUtc));
    }
    if (music != null) {
      out.addAll(music.add(features, atUtc));
    }
    if (speech != null) {
      out.addAll(speech.add(features, atUtc));
    }
    return out;
  }

  /// Closes any open snore episode. Call when the analysis gate closes.
  List<AcousticDetection> flush() {
    final out = <AcousticDetection>[];
    final snore = _snore;
    final sleep = _sleep;
    if (snore != null) {
      out.addAll(snore.flush());
    }
    if (sleep != null) {
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
