import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/pcm16_signal.dart';

Uint8List _pcm16(
  List<int> samples, {
  int prefixBytes = 0,
  bool oddTail = false,
}) {
  final bytes = Uint8List(prefixBytes + samples.length * 2 + (oddTail ? 1 : 0));
  final view = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index += 1) {
    view.setInt16(prefixBytes + index * 2, samples[index], Endian.little);
  }
  return bytes;
}

void main() {
  test('silent PCM remains below the physical signal threshold', () {
    final summary = summarizePcm16Signal(_pcm16(List<int>.filled(256, 0)));

    expect(summary.sampleCount, 256);
    expect(summary.nonTrivialSamples, 0);
    expect(summary.peakAbsolute, 0);
    expect(summary.observed(), isFalse);
  });

  test('sustained non-trivial PCM is recognized without retaining content', () {
    final samples = List<int>.generate(128, (index) => index.isEven ? 64 : -64);
    final summary = summarizePcm16Signal(_pcm16(samples));

    expect(summary.sampleCount, 128);
    expect(summary.nonTrivialSamples, 128);
    expect(summary.peakAbsolute, 64);
    expect(summary.observed(), isTrue);
  });

  test('one spike cannot satisfy the sustained-input contract', () {
    final samples = List<int>.filled(256, 0)..[120] = 4096;
    final summary = summarizePcm16Signal(_pcm16(samples));

    expect(summary.peakAbsolute, 4096);
    expect(summary.nonTrivialSamples, 1);
    expect(summary.observed(), isFalse);
  });

  test('WAV headers are excluded and an odd trailing byte is ignored', () {
    final bytes = _pcm16(
      List<int>.filled(80, 96),
      prefixBytes: 44,
      oddTail: true,
    );
    bytes.fillRange(0, 44, 0x7f);

    final summary = summarizePcm16Signal(bytes, payloadOffset: 44);

    expect(summary.sampleCount, 80);
    expect(summary.nonTrivialSamples, 80);
    expect(summary.peakAbsolute, 96);
    expect(summary.observed(), isTrue);
  });

  test('misaligned or invalid thresholds fail closed', () {
    final bytes = _pcm16(const [1, 2, 3]);

    expect(
      () => summarizePcm16Signal(bytes, payloadOffset: 1),
      throwsArgumentError,
    );
    expect(
      () => summarizePcm16Signal(bytes, nonTrivialThreshold: 0),
      throwsRangeError,
    );
    expect(
      () => summarizePcm16Signal(bytes, payloadOffset: bytes.length + 1),
      throwsRangeError,
    );
  });
}
