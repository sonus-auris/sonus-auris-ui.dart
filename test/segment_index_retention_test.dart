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
    expect(await _tombstoneFile(temp).exists(), isFalse);
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
    expect(await _tombstoneFile(temp).exists(), isFalse);
  });

  test('registered transcript and scratch artifacts expire with the audio', () async {
    final cutoff = DateTime.utc(2026, 7, 27, 12);
    final audio = await _writeArtifactSet(temp, 'registered.wav');
    final transcript = File(p.join(temp.path, 'segments', 'registered.transcript.json'));
    final scratch = File(p.join(temp.path, 'analysis', 'registered.scratch'));
    await transcript.writeAsString('{"text":"sensitive"}', flush: true);
    await scratch.parent.create(recursive: true);
    await scratch.writeAsBytes([4, 5, 6], flush: true);
    final segment = _segment(
      id: 'registered',
      audio: audio,
      endedAtUtc: cutoff,
      uploadStatus: SegmentUploadStatus.pending,
    );
    await index.saveSegments([segment]);
    await index.registerLocalArtifact(
      segmentId: segment.id,
      artifactPath: transcript.path,
    );
    await index.registerLocalArtifact(
      segmentId: segment.id,
      artifactPath: scratch.path,
    );

    final result = await index.enforceDeviceRetention(
      segments: await index.loadSegments(),
      cutoffUtc: cutoff,
    );

    expect(result.single.localPath, isNull);
    expect(await transcript.exists(), isFalse);
    expect(await scratch.exists(), isFalse);
    expect(
      await File(p.join(temp.path, 'segment-artifacts.v1.json')).exists(),
      isFalse,
    );
  });

  test('restart replays a tombstone after a crash before deletion', () async {
    final cutoff = DateTime.utc(2026, 7, 27, 12);
    final audio = await _writeArtifactSet(temp, 'crash-before-delete.wav');
    final segment = _segment(
      id: 'crash-before-delete',
      audio: audio,
      endedAtUtc: cutoff,
      uploadStatus: SegmentUploadStatus.pending,
    );
    await index.saveSegments([segment]);
    final crashing = SegmentIndex(
      baseDirectoryProvider: () async => temp,
      retentionMutationHook: (stage, _) async {
        if (stage == RetentionMutationStage.tombstonePersisted) {
          throw StateError('simulated process stop');
        }
      },
    );

    await expectLater(
      crashing.enforceDeviceRetention(
        segments: [segment],
        cutoffUtc: cutoff,
      ),
      throwsStateError,
    );
    expect(await audio.exists(), isTrue);
    expect(await _tombstoneFile(temp).exists(), isTrue);

    final restarted = SegmentIndex(baseDirectoryProvider: () async => temp);
    final recovered = await restarted.loadSegments();

    expect(await audio.exists(), isFalse);
    expect(await File(_sidecarPath(audio.path)).exists(), isFalse);
    expect(recovered.single.localPath, isNull);
    expect(recovered.single.uploadStatus, SegmentUploadStatus.failed);
    expect(await _tombstoneFile(temp).exists(), isFalse);
  });

  test('restart converges after files were deleted but index was stale', () async {
    final cutoff = DateTime.utc(2026, 7, 27, 12);
    final audio = await _writeArtifactSet(temp, 'crash-after-delete.wav');
    final segment = _segment(
      id: 'crash-after-delete',
      audio: audio,
      endedAtUtc: cutoff,
      uploadStatus: SegmentUploadStatus.pending,
    );
    await index.saveSegments([segment]);
    final crashing = SegmentIndex(
      baseDirectoryProvider: () async => temp,
      retentionMutationHook: (stage, _) async {
        if (stage == RetentionMutationStage.artifactsDeleted) {
          throw StateError('simulated process stop');
        }
      },
    );

    await expectLater(
      crashing.enforceDeviceRetention(
        segments: [segment],
        cutoffUtc: cutoff,
      ),
      throwsStateError,
    );
    expect(await audio.exists(), isFalse);
    expect(await _tombstoneFile(temp).exists(), isTrue);

    final restarted = SegmentIndex(baseDirectoryProvider: () async => temp);
    final recovered = await restarted.loadSegments();

    expect(recovered.single.localPath, isNull);
    expect(recovered.single.uploadStatus, SegmentUploadStatus.failed);
    expect(await _tombstoneFile(temp).exists(), isFalse);
  });

  test('retention deletes artifacts when the base directory is a symlink '
      'alias (iOS /var -> /private/var)', () async {
    final real = await Directory.systemTemp.createTemp('sonus-symlink-real-');
    final alias = Link(
      p.join(Directory.systemTemp.path, 'sonus-symlink-alias-${real.hashCode}'),
    );
    await alias.create(real.path);
    addTearDown(() async {
      if (await alias.exists()) await alias.delete();
      if (await real.exists()) await real.delete(recursive: true);
    });

    // The provider hands out the alias spelling; the artifact was recorded
    // under the real spelling. Before canonicalization this threw
    // "Refusing to delete an artifact outside app storage".
    final aliased = SegmentIndex(
      baseDirectoryProvider: () async => Directory(alias.path),
    );
    final audio = await _writeArtifactSet(real, 'sym.wav');
    final segment = _segment(
      id: 'sym',
      audio: audio,
      endedAtUtc: DateTime.utc(2026, 7, 27, 12),
      uploadStatus: SegmentUploadStatus.pending,
    );
    await aliased.saveSegments([segment]);

    final result = await aliased.enforceDeviceRetention(
      segments: [segment],
      cutoffUtc: DateTime.utc(2026, 7, 27, 13),
    );

    expect(result.single.error, isNull);
    expect(result.single.localPath, isNull);
    expect(await audio.exists(), isFalse);
    expect(await File(_sidecarPath(audio.path)).exists(), isFalse);
    expect(await File('${audio.path}.part').exists(), isFalse);
  });

  test('artifact registration rejects paths outside app storage', () async {
    final audio = await _writeArtifactSet(temp, 'bounded.wav');
    final segment = _segment(
      id: 'bounded',
      audio: audio,
      endedAtUtc: DateTime.utc(2026, 7, 27, 12),
      uploadStatus: SegmentUploadStatus.pending,
    );
    await index.saveSegments([segment]);
    final outside = File(p.join(temp.parent.path, '${temp.path.hashCode}.secret'));
    await outside.writeAsString('do not delete', flush: true);
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
    });

    await expectLater(
      index.registerLocalArtifact(
        segmentId: segment.id,
        artifactPath: outside.path,
      ),
      throwsStateError,
    );
    expect(await outside.exists(), isTrue);
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

File _tombstoneFile(Directory base) => File(
  p.join(base.path, SegmentIndex.retentionTombstoneFileName),
);
