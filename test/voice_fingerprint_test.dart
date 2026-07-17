import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_dashcam/src/services/voice_id/voice_fingerprinter.dart';
import 'package:audio_dashcam/src/services/voice_id/voice_profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic synthetic "voice": a pulse-ish harmonic stack at [pitchHz]
/// shaped by two formant resonances — enough spectral identity that two clips
/// of the same voice agree and different voices disagree.
Float64List syntheticVoice({
  required double pitchHz,
  required double formant1Hz,
  required double formant2Hz,
  int sampleRate = 16000,
  double seconds = 2.0,
  int seed = 1,
}) {
  final length = (sampleRate * seconds).round();
  final out = Float64List(length);
  final random = math.Random(seed);
  for (var i = 0; i < length; i++) {
    final t = i / sampleRate;
    var sample = 0.0;
    for (var h = 1; h <= 20; h++) {
      final freq = pitchHz * h;
      if (freq > sampleRate / 2) {
        break;
      }
      // Formant shaping: harmonics near the two formants are amplified.
      final d1 = (freq - formant1Hz) / 150.0;
      final d2 = (freq - formant2Hz) / 200.0;
      final gain = 0.1 + math.exp(-d1 * d1) + 0.7 * math.exp(-d2 * d2);
      sample += gain * math.sin(2 * math.pi * freq * t) / h;
    }
    // A little noise so clips of the "same voice" are not bit-identical.
    out[i] = 0.25 * sample + 0.005 * (random.nextDouble() * 2 - 1);
  }
  return out;
}

void main() {
  final fingerprinter = VoiceFingerprinter();

  group('VoiceFingerprinter', () {
    test('same synthetic voice matches itself across distinct clips', () {
      final clipA = syntheticVoice(
        pitchHz: 120,
        formant1Hz: 700,
        formant2Hz: 1200,
        seed: 1,
      );
      final clipB = syntheticVoice(
        pitchHz: 120,
        formant1Hz: 700,
        formant2Hz: 1200,
        seed: 99,
      );
      final fpA = fingerprinter.fingerprint(clipA);
      final fpB = fingerprinter.fingerprint(clipB);
      expect(fpA, isNotNull);
      expect(fpB, isNotNull);
      final similarity = VoiceFingerprinter.cosineSimilarity(fpA!, fpB!);
      expect(similarity, greaterThan(0.9));
    });

    test('different voices score clearly lower than the same voice', () {
      final voiceA = fingerprinter.fingerprint(
        syntheticVoice(pitchHz: 120, formant1Hz: 700, formant2Hz: 1200),
      )!;
      final voiceASecondClip = fingerprinter.fingerprint(
        syntheticVoice(
          pitchHz: 120,
          formant1Hz: 700,
          formant2Hz: 1200,
          seed: 7,
        ),
      )!;
      final voiceB = fingerprinter.fingerprint(
        syntheticVoice(pitchHz: 230, formant1Hz: 450, formant2Hz: 2600),
      )!;
      final same = VoiceFingerprinter.cosineSimilarity(
        voiceA,
        voiceASecondClip,
      );
      final different = VoiceFingerprinter.cosineSimilarity(voiceA, voiceB);
      expect(same, greaterThan(different));
      expect(different, lessThan(VoiceProfileService.matchThreshold));
    });

    test('silence and near-silence yield no fingerprint', () {
      expect(fingerprinter.fingerprint(Float64List(16000 * 2)), isNull);
      final hum = Float64List(16000);
      for (var i = 0; i < hum.length; i++) {
        hum[i] = 0.0005 * math.sin(2 * math.pi * 60 * i / 16000);
      }
      expect(fingerprinter.fingerprint(hum), isNull);
    });

    test('downsample halves 32 kHz audio to 16 kHz', () {
      final input = Float64List.fromList(
        List.generate(3200, (i) => math.sin(2 * math.pi * 440 * i / 32000)),
      );
      final output = VoiceFingerprinter.downsample(input, 32000, 16000);
      expect(output.length, 1600);
    });

    test('fingerprints are unit-norm so cosine is a dot product', () {
      final fp = fingerprinter.fingerprint(
        syntheticVoice(pitchHz: 150, formant1Hz: 600, formant2Hz: 1800),
      )!;
      final norm = math.sqrt(fp.fold<double>(0, (sum, v) => sum + v * v));
      expect(norm, closeTo(1.0, 1e-9));
    });
  });

  group('VoiceProfileService', () {
    late Directory tempDir;
    late VoiceProfileService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('voice-profile-test');
      service = VoiceProfileService(baseDirectoryProvider: () async => tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Float64List clip({int seed = 1}) => syntheticVoice(
      pitchHz: 120,
      formant1Hz: 700,
      formant2Hz: 1200,
      seed: seed,
    );

    test(
      'enrolls, persists, matches, and enforces the five-sample cap',
      () async {
        for (var i = 0; i < VoiceProfileService.maxSamples; i++) {
          final result = await service.enroll(
            mono: clip(seed: i),
            sampleRate: 16000,
          );
          expect(result.error, isNull);
          expect(result.sample, isNotNull);
          expect(File(result.sample!.wavPath!).existsSync(), isTrue);
        }
        final overflow = await service.enroll(mono: clip(), sampleRate: 16000);
        expect(overflow.sample, isNull);
        expect(overflow.error, contains('5'));

        // A fresh instance reloads the persisted fingerprints from disk.
        final reloaded = VoiceProfileService(
          baseDirectoryProvider: () async => tempDir,
        );
        expect(await reloaded.load(), hasLength(5));

        final match = await reloaded.match(
          mono: clip(seed: 42),
          sampleRate: 16000,
        );
        expect(match, isNotNull);
        expect(match!.isMatch, isTrue);

        final stranger = await reloaded.match(
          mono: syntheticVoice(pitchHz: 230, formant1Hz: 450, formant2Hz: 2600),
          sampleRate: 16000,
        );
        expect(stranger, isNotNull);
        expect(stranger!.isMatch, isFalse);
      },
    );

    test('rejects clips without enough speech', () async {
      final result = await service.enroll(
        mono: Float64List(16000),
        sampleRate: 16000,
      );
      expect(result.sample, isNull);
      expect(result.error, contains('speech'));
    });

    test('removeSample deletes the clip and the fingerprint', () async {
      final enrolled = await service.enroll(mono: clip(), sampleRate: 16000);
      final wavPath = enrolled.sample!.wavPath!;
      await service.removeSample(enrolled.sample!.id);
      expect(service.samples, isEmpty);
      expect(File(wavPath).existsSync(), isFalse);
      expect(await service.match(mono: clip(), sampleRate: 16000), isNull);
    });
  });
}
