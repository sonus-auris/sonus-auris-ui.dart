import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/recording_segment.dart';

class SegmentIndex {
  static const _indexFileName = 'segments.v1.json';

  Future<Directory> get segmentsDirectory async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory(p.join(base.path, 'segments'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> get _indexFile async {
    final base = await getApplicationSupportDirectory();
    return File(p.join(base.path, _indexFileName));
  }

  Future<List<RecordingSegment>> loadSegments() async {
    final file = await _indexFile;
    if (!await file.exists()) {
      return const [];
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const [];
    }
    try {
      final json = jsonDecode(raw) as List<dynamic>;
      final segments = json
          .cast<Map<String, dynamic>>()
          .map(RecordingSegment.fromJson)
          .toList();
      segments.sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
      return segments;
    } catch (_) {
      await _quarantineCorruptIndex(file);
      return const [];
    }
  }

  Future<void> saveSegments(List<RecordingSegment> segments) async {
    final file = await _indexFile;
    final sorted = [...segments]
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sorted.map((segment) => segment.toJson()).toList()),
      flush: true,
    );
    await tempFile.rename(file.path);
  }

  Future<void> clearAll() async {
    final file = await _indexFile;
    if (await file.exists()) {
      await file.delete();
    }
    final directory = await segmentsDirectory;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> upsertSegment(RecordingSegment segment) async {
    final segments = await loadSegments();
    final index = segments.indexWhere((item) => item.id == segment.id);
    if (index == -1) {
      segments.add(segment);
    } else {
      segments[index] = segment;
    }
    await saveSegments(segments);
  }

  Future<String> createSegmentPath(
    DateTime startedAtUtc, {
    String extension = '.m4a',
  }) async {
    final dir = await segmentsDirectory;
    final year = startedAtUtc.year.toString().padLeft(4, '0');
    final month = startedAtUtc.month.toString().padLeft(2, '0');
    final day = startedAtUtc.day.toString().padLeft(2, '0');
    final hour = startedAtUtc.hour.toString().padLeft(2, '0');
    final nestedDir = Directory(p.join(dir.path, year, month, day, hour));
    if (!await nestedDir.exists()) {
      await nestedDir.create(recursive: true);
    }
    final normalizedExtension = extension.startsWith('.')
        ? extension
        : '.$extension';
    return p.join(
      nestedDir.path,
      '${safeSegmentId(startedAtUtc)}$normalizedExtension',
    );
  }

  Future<List<RecordingSegment>> recoverOrphanedLocalSegments({
    required int fallbackSegmentMinutes,
  }) async {
    final segments = await loadSegments();
    final knownPaths = segments
        .where((segment) => segment.localPath != null)
        .map((segment) => p.normalize(segment.localPath!))
        .toSet();
    final directory = await segmentsDirectory;
    if (!await directory.exists()) {
      return segments;
    }
    final recovered = [...segments];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final extension = p.extension(entity.path).toLowerCase();
      if (entity is! File ||
          (extension != '.m4a' && extension != '.wav' && extension != '.pcm')) {
        continue;
      }
      if (knownPaths.contains(p.normalize(entity.path))) {
        continue;
      }
      final stat = await entity.stat();
      final endedAtUtc = stat.modified.toUtc();
      final startedAtUtc = endedAtUtc.subtract(
        Duration(minutes: fallbackSegmentMinutes.clamp(1, 60)),
      );
      recovered.add(
        RecordingSegment(
          id: safeSegmentId(startedAtUtc),
          startedAtUtc: startedAtUtc,
          endedAtUtc: endedAtUtc,
          localPath: entity.path,
          byteSize: stat.size,
          uploadStatus: SegmentUploadStatus.pending,
        ),
      );
    }
    await saveSegments(recovered);
    return recovered;
  }

  Future<List<RecordingSegment>> enforceDeviceRetention({
    required List<RecordingSegment> segments,
    required DateTime cutoffUtc,
  }) async {
    final updated = <RecordingSegment>[];
    for (final segment in segments) {
      if (segment.localPath == null || segment.endedAtUtc.isAfter(cutoffUtc)) {
        updated.add(segment);
        continue;
      }
      final canDeleteLocal = segment.isUploaded || segment.isPermanentlySaved;
      if (!canDeleteLocal) {
        updated.add(segment);
        continue;
      }
      final file = File(segment.localPath!);
      if (await file.exists()) {
        await file.delete();
      }
      updated.add(segment.copyWith(localPath: null));
    }
    await saveSegments(updated);
    return updated;
  }

  Future<List<RecordingSegment>> dropCloudExpiredRecords({
    required List<RecordingSegment> segments,
    required DateTime cutoffUtc,
  }) async {
    final retained = segments
        .where(
          (segment) =>
              segment.endedAtUtc.isAfter(cutoffUtc) ||
              segment.isLocal ||
              segment.isPermanentlySaved,
        )
        .toList();
    await saveSegments(retained);
    return retained;
  }

  static String safeSegmentId(DateTime utc) {
    final value = utc.toUtc().toIso8601String();
    return value.replaceAll(':', '-').replaceAll('.', '-').replaceAll('Z', 'z');
  }

  Future<void> _quarantineCorruptIndex(File file) async {
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final backup = File('${file.path}.corrupt.$timestamp');
    try {
      await file.rename(backup.path);
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {
        // Leave the corrupt file in place if the OS will not let us move it.
      }
    }
  }
}
