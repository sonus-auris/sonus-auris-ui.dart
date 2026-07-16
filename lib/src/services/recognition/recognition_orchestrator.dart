// Routes cheap FFT-gate detections to the expensive recognizers: music →
// ShazamKit, unclassified tonal sound → Perch bird ID. The gate keeps 24/7
// recognition near-zero cost — heavy models only run when something fired.
import 'dart:async';
import 'dart:typed_data';

import '../../models/acoustic_detection.dart';
import '../shazam_client.dart';
import 'bird_classifier.dart';

/// Supplies a short clip of audio around a detection, pulled from the rolling
/// buffer. [pcm16] is interleaved 16-bit PCM for ShazamKit; [monoFloat] is
/// normalized mono for the TFLite classifiers.
abstract class DetectionClipSource {
  Future<Uint8List?> pcm16Around(
    AcousticDetection detection, {
    required Duration length,
  });

  Future<Float32List?> monoFloatAround(
    AcousticDetection detection, {
    required Duration length,
    required int sampleRate,
  });
}

/// A recognition result enriched beyond the raw FFT detection.
class RecognitionResult {
  const RecognitionResult({required this.detection, required this.kind});

  /// The original detection with recognizer output merged into [AcousticDetection.details]
  /// (song title/artist for music, species/score for bird calls).
  final AcousticDetection detection;

  final RecognitionKind kind;
}

enum RecognitionKind { song, birdCall }

/// Listens to the FFT detector stream and invokes the matching recognizer.
///
/// Only detections that the cheap on-device gate already flagged reach the
/// expensive paths, and each recognizer is loaded lazily on first use — so
/// idle recording costs nothing extra in CPU, battery, or app size.
class RecognitionOrchestrator {
  RecognitionOrchestrator({
    required DetectionClipSource clips,
    ShazamClient? shazam,
    BirdClassifier? birds,
    this.songIdEnabled = true,
    this.birdIdEnabled = false,
  })  : _clips = clips,
        _shazam = shazam,
        _birds = birds;

  final DetectionClipSource _clips;
  final ShazamClient? _shazam;
  final BirdClassifier? _birds;

  /// Feature toggles, wired to settings. Bird ID is opt-in because it pulls a
  /// ~14 MB model on first enable.
  bool songIdEnabled;
  bool birdIdEnabled;

  final StreamController<RecognitionResult> _results =
      StreamController<RecognitionResult>.broadcast();
  StreamSubscription<AcousticDetection>? _subscription;

  Stream<RecognitionResult> get results => _results.stream;

  void bind(Stream<AcousticDetection> detections) {
    _subscription?.cancel();
    _subscription = detections.listen(_onDetection);
  }

  Future<void> _onDetection(AcousticDetection detection) async {
    try {
      switch (detection.kind) {
        case AcousticDetectionKind.music:
          await _identifySong(detection);
          break;
        case AcousticDetectionKind.speech:
        case AcousticDetectionKind.keyword:
        case AcousticDetectionKind.snore:
        case AcousticDetectionKind.apneaPattern:
        case AcousticDetectionKind.sleepCycle:
        case AcousticDetectionKind.sleepCycleAlarm:
          // Speech transcription and sleep events are handled by their own
          // services; the orchestrator only owns song and bird ID. Bird calls
          // surface as music-adjacent tonal detections, so try Perch on music
          // frames that ShazamKit did not match (see _identifySong).
          break;
      }
    } catch (_) {
      // Recognition is best-effort; a failed lookup must never disturb capture.
    }
  }

  Future<void> _identifySong(AcousticDetection detection) async {
    final shazam = _shazam;
    if (songIdEnabled && shazam != null && shazam.isSupported) {
      final pcm = await _clips.pcm16Around(
        detection,
        length: const Duration(seconds: 12),
      );
      if (pcm != null) {
        final match = await shazam.identify(
          pcm16: pcm,
          sampleRate: 44100,
          channels: 1,
        );
        if (match != null) {
          _results.add(RecognitionResult(
            kind: RecognitionKind.song,
            detection: detection.copyWith(
              details: {...detection.details, ...match.toDetails()},
            ),
          ));
          return;
        }
      }
    }
    // Tonal but not a catalog song — worth a bird-ID pass when enabled.
    await _identifyBird(detection);
  }

  Future<void> _identifyBird(AcousticDetection detection) async {
    final birds = _birds;
    if (!birdIdEnabled || birds == null) {
      return;
    }
    final samples = await _clips.monoFloatAround(
      detection,
      length: const Duration(seconds: 5),
      sampleRate: BirdClassifier.sampleRate,
    );
    if (samples == null) {
      return;
    }
    final matches = await birds.classify(samples);
    if (matches.isEmpty) {
      return;
    }
    _results.add(RecognitionResult(
      kind: RecognitionKind.birdCall,
      detection: detection.copyWith(
        details: {
          ...detection.details,
          ...matches.first.toDetails(),
          if (matches.length > 1)
            'alternates': [
              for (final m in matches.skip(1)) m.toDetails(),
            ],
        },
      ),
    ));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _results.close();
  }
}
