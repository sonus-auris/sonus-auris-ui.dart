// Writes a time-aligned FFT spectral-features JSON sidecar next to each finalized WAV segment.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/acoustic_detection.dart';
import '../models/recording_segment.dart';
import 'acoustic/music_detector.dart';
import 'acoustic/safety_sound_detector.dart';
import 'acoustic/speech_detector.dart';
import 'acoustic/spectral_features.dart';

/// Writes a **time-aligned spectral analysis track** next to each rolling WAV
/// segment — a parallel decomposition of the audio, derived by FFT.
///
/// This runs *after* a segment is finalized (off the realtime capture path) over
/// the just-written WAV, sliding an FFT across it (Hann window, 50% hop) and
/// recording one [SpectralFrame] worth of features per hop. The result is a
/// compact JSON sidecar `<stem>.features.json` alongside `<stem>.wav`, so audio
/// and analysis can be pruned/synced independently and the spectral track can be
/// reprocessed without re-recording.
///
/// The frames are an FFT *feature* decomposition (centroid, flatness, rolloff,
/// dominant bin, band energy ratios, level). A full magnitude spectrogram, mel
/// bands, chroma, etc. are natural future sidecars in the same scheme — see the
/// `kind` field, which lets multiple analysis tracks coexist.
class SpectralSidecar {
  SpectralSidecar({this.fftSize = 1024})
    : assert(
        fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
        'fftSize must be a power of two',
      );

  final int fftSize;

  static const int formatVersion = 2;

  /// Sidecar path for a given audio path: `foo.wav` -> `foo.features.json`.
  static String sidecarPathFor(String audioPath) {
    final dot = audioPath.lastIndexOf('.');
    final stem = dot < 0 ? audioPath : audioPath.substring(0, dot);
    return '$stem.features.json';
  }

  /// Analyze a finished segment's WAV and write its spectral sidecar. Best-effort
  /// and side-effect-free on failure: returns the sidecar file, or null if the
  /// audio is missing, unreadable, or shorter than one FFT frame.
  Future<File?> writeForSegment(RecordingSegment segment) async {
    final path = segment.localPath;
    if (path == null) {
      return null;
    }
    return writeForWav(
      path,
      sampleRate: segment.sampleRate,
      channels: segment.channels,
      startedAtUtc: segment.startedAtUtc,
      captureSessionId: segment.captureSessionId,
    );
  }

  Future<File?> writeForWav(
    String wavPath, {
    required int sampleRate,
    required int channels,
    DateTime? startedAtUtc,
    String captureSessionId = '',
  }) async {
    final file = File(wavPath);
    if (!await file.exists()) {
      return null;
    }
    final bytes = await file.readAsBytes();
    // 44-byte canonical WAV header written by WavSegmentWriter; PCM16 follows.
    if (bytes.length <= 44 || sampleRate <= 0) {
      return null;
    }
    final mono = pcm16BytesToMonoDoubles(
      Uint8List.sublistView(bytes, 44),
      channels,
    );
    if (mono.length < fftSize) {
      return null;
    }

    final analyzer = SpectralAnalyzer(fftSize: fftSize, sampleRate: sampleRate);
    final hop = fftSize ~/ 2;
    final frameSeconds = hop / sampleRate;
    final music = MusicDetector(
      frameSeconds: frameSeconds,
      captureSessionId: captureSessionId,
    );
    final speech = SpeechDetector(
      frameSeconds: frameSeconds,
      captureSessionId: captureSessionId,
    );
    final safety = SafetySoundDetector(
      frameSeconds: frameSeconds,
      captureSessionId: captureSessionId,
    );
    final baseUtc =
        (startedAtUtc ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
            .toUtc();
    final frame = Float64List(fftSize);
    final frames = <List<num>>[];
    final detections = <AcousticDetection>[];
    var maxDb = -120.0;
    var maxPeakAmplitude = 0.0;
    var maxClippingFraction = 0.0;
    var highBandSum = 0.0;
    for (var start = 0; start + fftSize <= mono.length; start += hop) {
      for (var i = 0; i < fftSize; i++) {
        frame[i] = mono[start + i];
      }
      final f = analyzer.analyze(frame);
      if (f.db > maxDb) {
        maxDb = f.db;
      }
      if (f.peakAmplitude > maxPeakAmplitude) {
        maxPeakAmplitude = f.peakAmplitude;
      }
      if (f.clippingFraction > maxClippingFraction) {
        maxClippingFraction = f.clippingFraction;
      }
      highBandSum += f.highBandRatio;
      final atUtc = baseUtc.add(
        Duration(
          microseconds: ((start + fftSize) * 1000000 / sampleRate).round(),
        ),
      );
      detections.addAll(music.add(f, atUtc));
      detections.addAll(speech.add(f, atUtc));
      detections.addAll(safety.add(f, atUtc));
      frames.add([
        (start * 1000 / sampleRate).round(), // tMs: frame start offset
        _round(f.db, 1),
        _round(f.centroidHz, 1),
        _round(f.flatness, 4),
        _round(f.rolloffHz, 1),
        _round(f.dominantHz, 1),
        _round(f.lowBandRatio, 4),
        _round(f.speechBandRatio, 4),
        _round(f.peakAmplitude, 4),
        _round(f.crestFactor, 3),
        _round(f.highBandRatio, 4),
        _round(f.clippingFraction, 5),
        _round(f.crest, 3),
      ]);
    }
    detections.addAll(safety.flush());

    final classificationCounts = <String, int>{};
    for (final detection in detections) {
      classificationCounts.update(
        detection.kind.name,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final summary = <String, dynamic>{
      'heuristic': true,
      'onDevice': true,
      'transcriptionUsed': false,
      'maxDb': _round(maxDb, 1),
      'maxPeakAmplitude': _round(maxPeakAmplitude, 4),
      'maxClippingFraction': _round(maxClippingFraction, 5),
      'meanHighBandRatio': _round(highBandSum / frames.length, 4),
      'classificationCounts': classificationCounts,
      'events': detections
          .map(
            (detection) => {
              'kind': detection.kind.name,
              'startMs': detection.startedAtUtc
                  .difference(baseUtc)
                  .inMilliseconds
                  .clamp(0, 1 << 31),
              'endMs': detection.endedAtUtc
                  .difference(baseUtc)
                  .inMilliseconds
                  .clamp(0, 1 << 31),
              'confidence': _round(detection.confidence, 3),
              'details': detection.details,
            },
          )
          .toList(growable: false),
      'caveat':
          'Sound classes are acoustic patterns, not proof of an accident, argument, speaker count, or identity.',
    };

    final payload = <String, dynamic>{
      'version': formatVersion,
      'kind': 'spectral-features',
      'sampleRate': sampleRate,
      'fftSize': fftSize,
      'hop': hop,
      'fields': const [
        'tMs',
        'db',
        'centroidHz',
        'flatness',
        'rolloffHz',
        'dominantHz',
        'lowBandRatio',
        'speechBandRatio',
        'peakAmplitude',
        'crestFactor',
        'highBandRatio',
        'clippingFraction',
        'spectralCrest',
      ],
      'frames': frames,
      'summary': summary,
    };

    final sidecar = File(sidecarPathFor(wavPath));
    await sidecar.writeAsString(jsonEncode(payload), flush: true);
    return sidecar;
  }

  static num _round(double v, int dp) {
    if (v.isNaN || v.isInfinite) {
      return 0;
    }
    final factor = _pow10(dp);
    return (v * factor).round() / factor;
  }

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
