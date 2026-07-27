import 'dart:io';

import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/segment_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late SegmentIndex index;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sonus-retention-test-');
    index = SegmentIndex(baseDirectoryProvider: () async => temp);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('expired pending plaintext is deleted even before backup', () async {
    final cutoff = DateTime.utc(2026, 7, 27, 12);
    final audio = await _writeArtifactSet(temp, 'expired-pending.wav');
    final segment = _segment(
      id: 'expired-pending',
      audio: audio,
      endedAtUtc: cutoff,
      uploadStatus: SegmentUploadStatus.pending,
    );

    final result = await index.enforceDeviceRetention(
      segments: [segment],
      cutoffUtc: cutoff,
    );

    expect(await audio.exists(), isFalse);
    expect(await File(_sidecarPath(audio.path)).exists(), isFalse);
    expect(await File('${audio.path}.part').exists(), isFalse);
    expect(result.single.localPath, isNull);
    expect(result.single.uploadStatus, SegmentUploadStatus.failed);
    expect(
      result.single.error,
      startsWith(SegmentIndex.retentionExpiredErrorPrefix),
    );

    final persisted = await index.loadSegments();
    expect(persisted.single.localPath, isNull);
    expect(persisted.single.uploadStatus, SegmentUploadStatus.failed);
  });

  test('segment one instant inside the window is retained', () async {
    final cutoff = DateTime.utc(2026, 7, 27, 12);
    final audio = await _writeArtifactSet(temp, 'recent.wav');
    final segment = _segment(
      id: 'recent',
      audio: audio,
      endedAtUtc: cutoff.add(const Duration(microseconds: 1)),
      uploadStatus: SegmentUploadStatus.pending,
    );

    final result = await index.enforceDeviceRetention(
      segments: [segment],
      cutoffUtc: cutoff,
    );

    expect(await audio.exists(), isTrue);
    expect(await File(_sidecarPath(audio.path)).exists(), isTrue);
    expect(result.single.localPath, audio.path);
    expect(result.single.uploadStatus, SegmentUploadStatus.pending);
  });

  test('expired uploaded segment loses local artifacts but keeps remote state', () async {
    final cutoff = DateTime.utc(2026, 7, 27, 12);
    final audio = await _writeArtifactSet(temp, 'uploaded.wav');
    final segment = _segment(
      id: 'uploaded',
      audio: audio,
      endedAtUtc: cutoff.subtract(const Duration(seconds: 1)),
      uploadStatus: SegmentUploadStatus.uploaded,
      remoteKey: 'ciphertext/uploaded.sac',
    );

    final result = await index.enforceDeviceRetention(
      segments: [segment],
      cutoffUtc: cutoff,
    );

    expect(await audio.exists(), isFalse);
    expect(await File(_sidecarPath(audio.path)).exists(), isFalse);
    expect(result.single.localPath, isNull);
    expect(result.single.uploadStatus, SegmentUploadStatus.uploaded);
    expect(result.single.remoteKey, 'ciphertext/uploaded.sac');
    expect(result.single.error, isNull);
  });

  test('free-space cleanup also deletes sensitive companions', () async {
    final audio = await _writeArtifactSet(temp, 'space.wav');
    final segment = _segment(
      id: 'space',
      audio: audio,
      endedAtUtc: DateTime.utc(2026, 7, 27, 12),
      uploadStatus: SegmentUploadStatus.uploaded,
      remoteKey: 'ciphertext/space.sac',
    );

    final result = await index.enforceFreeSpaceFloor(
      segments: [segment],
      minFreeBytes: 1,
      freeBytes: (_) async => 0,
    );

    expect(await audio.exists(), isFalse);
    expect(await File(_sidecarPath(audio.path)).exists(), isFalse);
    expect(await File('${audio.path}.part').exists(), isFalse);
    expect(result.single.localPath, isNull);
    expect(result.single.remoteKey, 'ciphertext/space.sac');
  });
}

Future<File> _writeArtifactSet(Directory base, String name) async {
  final directory = Directory(p.join(base.path, 'segments'));
  await directory.create(recursive: true);
  final audio = File(p.join(directory.path, name));
  await audio.writeAsBytes(List<int>.filled(128, 1), flush: true);
  await File(_sidecarPath(audio.path)).writeAsString('{"sensitive":true}');
  await File('${audio.path}.part').writeAsBytes([1, 2, 3], flush: true);
  return audio;
}

RecordingSegment _segment({
  required String id,
  required File audio,
  required DateTime endedAtUtc,
  required SegmentUploadStatus uploadStatus,
  String? remoteKey,
}) {
  return RecordingSegment(
    id: id,
    startedAtUtc: endedAtUtc.subtract(const Duration(minutes: 1)),
    endedAtUtc: endedAtUtc,
    localPath: audio.path,
    byteSize: 128,
    uploadStatus: uploadStatus,
    remoteKey: remoteKey,
  );
}

String _sidecarPath(String audioPath) {
  final dot = audioPath.lastIndexOf('.');
  final stem = dot < 0 ? audioPath : audioPath.substring(0, dot);
  return '$stem.features.json';
}
