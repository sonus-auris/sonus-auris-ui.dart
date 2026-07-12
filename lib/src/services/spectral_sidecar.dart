// Writes a time-aligned FFT spectral-features JSON sidecar next to each finalized WAV segment.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/recording_segment.dart';
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
      : assert(fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
            'fftSize must be a power of two');

  final int fftSize;

  static const int formatVersion = 1;

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
    );
  }

  Future<File?> writeForWav(
    String wavPath, {
    required int sampleRate,
    required int channels,
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
    final frame = Float64List(fftSize);
    final frames = <List<num>>[];
    for (var start = 0; start + fftSize <= mono.length; start += hop) {
      for (var i = 0; i < fftSize; i++) {
        frame[i] = mono[start + i];
      }
      final f = analyzer.analyze(frame);
      frames.add([
        (start * 1000 / sampleRate).round(), // tMs: frame start offset
        _round(f.db, 1),
        _round(f.centroidHz, 1),
        _round(f.flatness, 4),
        _round(f.rolloffHz, 1),
        _round(f.dominantHz, 1),
        _round(f.lowBandRatio, 4),
        _round(f.speechBandRatio, 4),
      ]);
    }

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
      ],
      'frames': frames,
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
