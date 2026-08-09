import 'dart:typed_data';

/// Content-free PCM16 signal metrics for the isolated device-lab probe.
///
/// The summary never retains or serializes sample values. It only records a
/// sample count, a threshold crossing count, and an absolute peak so a physical
/// microphone run can distinguish an opened-but-silent stream from real input.
final class Pcm16SignalSummary {
  const Pcm16SignalSummary({
    required this.sampleCount,
    required this.nonTrivialSamples,
    required this.peakAbsolute,
  });

  final int sampleCount;
  final int nonTrivialSamples;
  final int peakAbsolute;

  bool observed({
    int minimumPeakAbsolute = 32,
    int minimumNonTrivialSamples = 64,
  }) {
    return peakAbsolute >= minimumPeakAbsolute &&
        nonTrivialSamples >= minimumNonTrivialSamples;
  }
}

Pcm16SignalSummary summarizePcm16Signal(
  Uint8List bytes, {
  int payloadOffset = 0,
  int nonTrivialThreshold = 8,
}) {
  if (payloadOffset < 0 || payloadOffset > bytes.length) {
    throw RangeError.range(payloadOffset, 0, bytes.length, 'payloadOffset');
  }
  if (payloadOffset.isOdd) {
    throw ArgumentError.value(
      payloadOffset,
      'payloadOffset',
      'PCM16 payloads must begin on a two-byte boundary',
    );
  }
  if (nonTrivialThreshold < 1 || nonTrivialThreshold > 32768) {
    throw RangeError.range(
      nonTrivialThreshold,
      1,
      32768,
      'nonTrivialThreshold',
    );
  }

  final view = ByteData.sublistView(bytes);
  final sampleCount = (bytes.length - payloadOffset) ~/ 2;
  var nonTrivialSamples = 0;
  var peakAbsolute = 0;
  for (var offset = payloadOffset; offset + 1 < bytes.length; offset += 2) {
    final absolute = view.getInt16(offset, Endian.little).abs();
    if (absolute > peakAbsolute) {
      peakAbsolute = absolute;
    }
    if (absolute >= nonTrivialThreshold) {
      nonTrivialSamples += 1;
    }
  }

  return Pcm16SignalSummary(
    sampleCount: sampleCount,
    nonTrivialSamples: nonTrivialSamples,
    peakAbsolute: peakAbsolute,
  );
}
