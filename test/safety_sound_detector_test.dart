import 'package:audio_dashcam/src/models/acoustic_detection.dart';
import 'package:audio_dashcam/src/services/acoustic/safety_sound_detector.dart';
import 'package:audio_dashcam/src/services/acoustic/spectral_features.dart';
import 'package:flutter_test/flutter_test.dart';

SpectralFrame _frame({
  double db = -60,
  double rms = 0.001,
  double peakAmplitude = 0.002,
  double crestFactor = 2,
  double flatness = 0.05,
  double spectralCrest = 20,
  double dominantHz = 600,
  double speechBandRatio = 0.1,
  double highBandRatio = 0.05,
  double clippingFraction = 0,
}) {
  return SpectralFrame(
    rms: rms,
    db: db,
    centroidHz: 1200,
    flatness: flatness,
    crest: spectralCrest,
    rolloffHz: 3000,
    dominantHz: dominantHz,
    lowBandRatio: 0.05,
    speechBandRatio: speechBandRatio,
    totalPower: 1,
    peakAmplitude: peakAmplitude,
    crestFactor: crestFactor,
    highBandRatio: highBandRatio,
    clippingFraction: clippingFraction,
  );
}

void main() {
  final base = DateTime.utc(2026, 7, 16, 12);

  test('detects a sudden broadband loud noise after a quiet baseline', () {
    final detector = SafetySoundDetector(frameSeconds: 0.064);
    expect(detector.add(_frame(), base), isEmpty);

    final events = detector.add(
      _frame(
        db: -6,
        rms: 0.5,
        peakAmplitude: 1,
        crestFactor: 5,
        flatness: 0.6,
        speechBandRatio: 0.25,
        highBandRatio: 0.5,
        clippingFraction: 0.02,
      ),
      base.add(const Duration(milliseconds: 64)),
    );

    expect(events, hasLength(1));
    expect(events.single.kind, AcousticDetectionKind.suddenLoudNoise);
    expect(events.single.details['riseDb'], greaterThan(40));
    expect(events.single.details['caveat'], contains('Not proof'));
  });

  test('does not call a sustained pure tone a voice or impact', () {
    final detector = SafetySoundDetector(frameSeconds: 0.1);
    final events = <AcousticDetection>[];
    for (var i = 0; i < 30; i++) {
      events.addAll(
        detector.add(
          _frame(
            db: -4,
            rms: 0.63,
            peakAmplitude: 0.9,
            crestFactor: 1.42,
            flatness: 0,
            spectralCrest: 400,
            dominantHz: 1000,
            speechBandRatio: 0.99,
            highBandRatio: 0,
          ),
          base.add(Duration(milliseconds: i * 100)),
        ),
      );
    }
    events.addAll(detector.flush());
    expect(events, isEmpty);
  });

  test('emits one raised-voice event for one continuous loud episode', () {
    final detector = SafetySoundDetector(frameSeconds: 0.1);
    final events = <AcousticDetection>[];
    for (var i = 0; i < 30; i++) {
      events.addAll(
        detector.add(
          _frame(
            db: -9,
            rms: 0.35,
            peakAmplitude: 0.75,
            crestFactor: 1.8,
            flatness: 0.08,
            spectralCrest: 35,
            speechBandRatio: 0.72,
            highBandRatio: 0.03,
          ),
          base.add(Duration(milliseconds: i * 100)),
        ),
      );
    }
    events.addAll(detector.flush());

    expect(
      events.where((event) => event.kind == AcousticDetectionKind.raisedVoice),
      hasLength(1),
    );
    expect(
      events.where(
        (event) => event.kind == AcousticDetectionKind.possibleArgumentPattern,
      ),
      isEmpty,
    );
  });

  test(
    'requires distinct raised-voice bursts for possible argument pattern',
    () {
      final detector = SafetySoundDetector(frameSeconds: 0.1);
      final events = <AcousticDetection>[];
      var frameIndex = 0;
      for (var burst = 0; burst < 3; burst++) {
        for (var i = 0; i < 6; i++) {
          events.addAll(
            detector.add(
              _frame(
                db: -8,
                rms: 0.4,
                peakAmplitude: 0.8,
                crestFactor: 1.8,
                flatness: 0.1,
                spectralCrest: 30,
                speechBandRatio: 0.75,
                highBandRatio: 0.04,
              ),
              base.add(Duration(milliseconds: frameIndex++ * 100)),
            ),
          );
        }
        for (var i = 0; i < 3; i++) {
          events.addAll(
            detector.add(
              _frame(),
              base.add(Duration(milliseconds: frameIndex++ * 100)),
            ),
          );
        }
      }

      expect(
        events.where(
          (event) => event.kind == AcousticDetectionKind.raisedVoice,
        ),
        hasLength(3),
      );
      final patterns = events
          .where(
            (event) =>
                event.kind == AcousticDetectionKind.possibleArgumentPattern,
          )
          .toList();
      expect(patterns, hasLength(1));
      expect(patterns.single.details['raisedVoiceBursts'], 3);
      expect(patterns.single.details['caveat'], contains('Not proof'));
    },
  );
}
