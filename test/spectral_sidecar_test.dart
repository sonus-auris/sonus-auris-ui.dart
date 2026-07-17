import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_dashcam/src/services/spectral_sidecar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sidecar path derivation', () {
    expect(
      SpectralSidecar.sidecarPathFor('/a/b/clip.wav'),
      '/a/b/clip.features.json',
    );
  });

  test(
    'writes a spectral track whose dominant bin tracks a 1 kHz tone',
    () async {
      const rate = 16000;
      const freq = 1000;
      const samples = rate; // 1 second
      final pcm = BytesBuilder();
      pcm.add(Uint8List(44)); // placeholder WAV header (skipped on read)
      final one = ByteData(2);
      for (var i = 0; i < samples; i++) {
        final v = (sin(2 * pi * freq * i / rate) * 20000).round();
        one.setInt16(0, v, Endian.little);
        pcm.add(one.buffer.asUint8List());
      }
      final dir = await Directory.systemTemp.createTemp('sonus-spec');
      final wav = File('${dir.path}/clip.wav');
      await wav.writeAsBytes(pcm.toBytes());

      final sidecar = await SpectralSidecar(
        fftSize: 1024,
      ).writeForWav(wav.path, sampleRate: rate, channels: 1);
      expect(sidecar, isNotNull);
      expect(sidecar!.path, endsWith('.features.json'));

      final json =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      expect(json['version'], 2);
      expect(json['kind'], 'spectral-features');
      expect(json['sampleRate'], rate);
      expect(
        json['fields'],
        containsAll([
          'peakAmplitude',
          'crestFactor',
          'highBandRatio',
          'clippingFraction',
          'spectralCrest',
        ]),
      );
      final frames = json['frames'] as List;
      expect(frames, isNotEmpty);

      final summary = json['summary'] as Map<String, dynamic>;
      expect(summary['heuristic'], isTrue);
      expect(summary['onDevice'], isTrue);
      expect(summary['transcriptionUsed'], isFalse);
      expect(summary['maxPeakAmplitude'], greaterThan(0.5));
      expect(summary['classificationCounts'], isEmpty);
      expect(summary['caveat'], contains('not proof'));

      // fields = [tMs, db, centroidHz, flatness, rolloffHz, dominantHz, ...]
      final dominant = frames.map((f) => (f as List)[5] as num).toList()
        ..sort();
      final median = dominant[dominant.length ~/ 2];
      // Bin width is 16000/1024 ≈ 15.6 Hz; the dominant bin should sit on ~1 kHz.
      expect(
        (median - 1000).abs() < 60,
        isTrue,
        reason: 'median dominantHz=$median',
      );

      await dir.delete(recursive: true);
    },
  );
}
