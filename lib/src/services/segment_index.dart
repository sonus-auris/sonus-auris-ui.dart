// On-disk JSON index and file storage for recorded segments (the rolling-buffer catalog).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/recording_segment.dart';

typedef SegmentBaseDirectoryProvider = Future<Directory> Function();
typedef RetentionMutationHook =
    Future<void> Function(RetentionMutationStage stage, String segmentId);

enum RetentionMutationStage {
  tombstonePersisted,
  artifactsDeleted,
  indexPersisted,
}

enum _LocalDeletionReason { retention, freeSpace }

class SegmentIndex {
  SegmentIndex({
    SegmentBaseDirectoryProvider? baseDirectoryProvider,
    RetentionMutationHook? retentionMutationHook,
  }) : _baseDirectoryProvider =
           baseDirectoryProvider ?? getApplicationSupportDirectory,
       // Preserve the public test-hook parameter name without exposing a private
       // named argument solely to satisfy the initializing-formal preference.
       // ignore: prefer_initializing_formals
       _retentionMutationHook = retentionMutationHook;

  static const _indexFileName = 'segments.v1.json';
  static const _artifactInventoryFileName = 'segment-artifacts.v1.json';
  static const retentionTombstoneFileName = 'retention-tombstones.v1.json';
  static const retentionExpiredErrorPrefix =
      'Local plaintext expired before backup completed';

  final SegmentBaseDirectoryProvider _baseDirectoryProvider;
  final RetentionMutationHook? _retentionMutationHook;

  Future<Directory> get segmentsDirectory async {
    final base = await _baseDirectoryProvider();
    final directory = Directory(p.join(base.path, 'segments'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> get _indexFile async {
    final base = await _baseDirectoryProvider();
    return File(p.join(base.path, _indexFileName));
  }

  Future<File> get _artifactInventoryFile async {
    final base = await _baseDirectoryProvider();
    return File(p.join(base.path, _artifactInventoryFileName));
  }

  Future<File> get _retentionTombstoneFile async {
    final base = await _baseDirectoryProvider();
    return File(p.join(base.path, retentionTombstoneFileName));
  }

  Future<List<RecordingSegment>> loadSegments() async {
    final file = await _indexFile;
    var segments = <RecordingSegment>[];
    if (await file.exists()) {
      final raw = await file.readAsString();
      if (raw.trim().isNotEmpty) {
        try {
          final json = jsonDecode(raw) as List<dynamic>;
          segments = json
              .cast<Map<String, dynamic>>()
              .map(RecordingSegment.fromJson)
              .toList();
        } catch (_) {
          await _quarantineCorruptIndex(file);
        }
      }
    }

    segments = await _reconcileRetentionTombstones(segments);
    segments.sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    return segments;
  }

  Future<void> saveSegments(List<RecordingSegment> segments) async {
    final file = await _indexFile;
    final sorted = [...segments]
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    await _atomicWriteJson(
      file,
      sorted.map((segment) => segment.toJson()).toList(),
    );
  }

  Future<void> clearAll() async {
    for (final file in [
      await _indexFile,
      await _artifactInventoryFile,
      await _retentionTombstoneFile,
    ]) {
      if (await file.exists()) {
        await file.delete();
      }
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

  /// Registers a sensitive derived local artifact with the segment retention
  /// unit. Workers must register transcripts, temporary analysis output,
  /// assembled clips, and caches before exposing them to later processing.
  Future<void> registerLocalArtifact({
    required String segmentId,
    required String artifactPath,
  }) async {
    final normalized = await _validatedArtifactPath(artifactPath);
    final segments = await loadSegments();
    final segment = segments.where((item) => item.id == segmentId).firstOrNull;
    if (segment == null) {
      throw StateError(
        'Cannot register an artifact for unknown segment $segmentId',
      );
    }
    if (!segment.isLocal) {
      throw StateError(
        'Cannot register an artifact after local plaintext was removed for $segmentId',
      );
    }

    final inventory = await _readArtifactInventory();
    final paths = <String>{...?inventory[segmentId], normalized}.toList()
      ..sort();
    inventory[segmentId] = paths;
    await _saveArtifactInventory(inventory);
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

  /// Enforces the local plaintext ceiling independently of upload success.
  ///
  /// A tombstone is flushed before deleting any artifact. If the process stops
  /// between deletion and index persistence, [loadSegments] replays the journal
  /// until the file system and metadata converge.
  Future<List<RecordingSegment>> enforceDeviceRetention({
    required List<RecordingSegment> segments,
    required DateTime cutoffUtc,
  }) async {
    final cutoff = cutoffUtc.toUtc();
    final updated = <RecordingSegment>[];
    final completed = <_RetentionTombstone>[];

    for (final segment in segments) {
      final localPath = segment.localPath;
      if (localPath == null || segment.endedAtUtc.isAfter(cutoff)) {
        updated.add(segment);
        continue;
      }

      final expiredBeforeBackup =
          !segment.isUploaded && !segment.isPermanentlySaved;
      final tombstone = _RetentionTombstone(
        segmentId: segment.id,
        reason: _LocalDeletionReason.retention,
        cutoffUtc: cutoff,
        expiredBeforeBackup: expiredBeforeBackup,
        artifactPaths: await _artifactPathsForSegment(segment),
      );
      await _putRetentionTombstone(tombstone);
      await _notifyMutation(
        RetentionMutationStage.tombstonePersisted,
        segment.id,
      );

      try {
        await _deleteArtifactPaths(tombstone.artifactPaths);
      } catch (error) {
        updated.add(
          segment.copyWith(error: 'Local retention deletion failed: $error'),
        );
        continue;
      }
      await _notifyMutation(
        RetentionMutationStage.artifactsDeleted,
        segment.id,
      );

      updated.add(_applyTombstone(segment, tombstone));
      completed.add(tombstone);
    }

    await saveSegments(updated);
    for (final tombstone in completed) {
      await _notifyMutation(
        RetentionMutationStage.indexPersisted,
        tombstone.segmentId,
      );
    }
    await _completeRetentionTombstones(completed);
    return updated;
  }

  /// "Space permitting": the rolling window keeps up to the configured hours,
  /// but never at the cost of filling the disk. Backed-up local copies are
  /// removed oldest-first, using the same crash-safe artifact journal.
  Future<List<RecordingSegment>> enforceFreeSpaceFloor({
    required List<RecordingSegment> segments,
    required int minFreeBytes,
    required Future<int?> Function(String path) freeBytes,
  }) async {
    final directory = await segmentsDirectory;
    final free = await freeBytes(directory.path);
    if (free == null || free >= minFreeBytes) {
      return segments;
    }
    var reclaimed = 0;
    final byAge = [...segments]
      ..sort((a, b) => a.endedAtUtc.compareTo(b.endedAtUtc));
    final replacements = <String, RecordingSegment>{};
    final completed = <_RetentionTombstone>[];

    for (final segment in byAge) {
      if (free + reclaimed >= minFreeBytes) {
        break;
      }
      if (!segment.isLocal ||
          !(segment.isUploaded || segment.isPermanentlySaved)) {
        continue;
      }
      final file = File(segment.localPath!);
      var bytes = segment.byteSize;
      if (await file.exists()) {
        try {
          bytes = await file.length();
        } catch (_) {}
      }

      final tombstone = _RetentionTombstone(
        segmentId: segment.id,
        reason: _LocalDeletionReason.freeSpace,
        cutoffUtc: DateTime.now().toUtc(),
        expiredBeforeBackup: false,
        artifactPaths: await _artifactPathsForSegment(segment),
      );
      await _putRetentionTombstone(tombstone);
      try {
        await _deleteArtifactPaths(tombstone.artifactPaths);
      } catch (_) {
        continue;
      }
      reclaimed += bytes;
      replacements[segment.id] = _applyTombstone(segment, tombstone);
      completed.add(tombstone);
    }
    if (replacements.isEmpty) {
      return segments;
    }
    final updated = segments
        .map((segment) => replacements[segment.id] ?? segment)
        .toList();
    await saveSegments(updated);
    await _completeRetentionTombstones(completed);
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

  Future<List<String>> _artifactPathsForSegment(
    RecordingSegment segment,
  ) async {
    final audioPath = await _validatedArtifactPath(segment.localPath!);
    final inventory = await _readArtifactInventory();
    final paths = <String>{
      _spectralSidecarPath(audioPath),
      '$audioPath.part',
      ...?inventory[segment.id],
      audioPath,
    };

    final validated = <String>[];
    for (final path in paths) {
      validated.add(await _validatedArtifactPath(path));
    }
    // Preserve the canonical audio path as the final deletion step.
    validated.remove(audioPath);
    validated.sort();
    validated.add(audioPath);
    return validated;
  }

  Future<String> _validatedArtifactPath(String artifactPath) async {
    final raw = artifactPath.trim();
    if (raw.isEmpty) {
      throw ArgumentError.value(
        artifactPath,
        'artifactPath',
        'must not be empty',
      );
    }
    final base = await _canonicalizedPath(
      (await _baseDirectoryProvider()).absolute.path,
    );
    final normalized = await _canonicalizedPath(File(raw).absolute.path);
    if (!p.equals(base, normalized) && !p.isWithin(base, normalized)) {
      throw StateError('Refusing to delete an artifact outside app storage');
    }
    return normalized;
  }

  /// Containment must compare canonical paths, not spellings: iOS app storage
  /// sits under the `/var` -> `/private/var` alias, so the base directory and
  /// an artifact path can name the same location two different ways depending
  /// on which platform API produced them. A path whose entity does not exist
  /// yet (already-deleted artifact) is canonicalized through its nearest
  /// existing ancestor so retention retries still validate.
  Future<String> _canonicalizedPath(String absolutePath) async {
    var existing = p.normalize(absolutePath);
    final remainder = <String>[];
    while (true) {
      try {
        final resolved = await File(existing).resolveSymbolicLinks();
        return p.normalize(p.joinAll([resolved, ...remainder.reversed]));
      } on FileSystemException {
        final parent = p.dirname(existing);
        if (parent == existing) {
          return p.normalize(absolutePath);
        }
        remainder.add(p.basename(existing));
        existing = parent;
      }
    }
  }

  Future<void> _deleteArtifactPaths(List<String> artifactPaths) async {
    for (final path in artifactPaths) {
      final validated = await _validatedArtifactPath(path);
      final file = File(validated);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  RecordingSegment _applyTombstone(
    RecordingSegment segment,
    _RetentionTombstone tombstone,
  ) {
    final expiredBeforeBackup =
        tombstone.reason == _LocalDeletionReason.retention &&
        tombstone.expiredBeforeBackup;
    return segment.copyWith(
      localPath: null,
      uploadStatus: expiredBeforeBackup
          ? SegmentUploadStatus.failed
          : segment.uploadStatus,
      error: expiredBeforeBackup
          ? '$retentionExpiredErrorPrefix at ${tombstone.cutoffUtc.toIso8601String()}.'
          : segment.error,
    );
  }

  Future<List<RecordingSegment>> _reconcileRetentionTombstones(
    List<RecordingSegment> segments,
  ) async {
    final tombstones = await _readRetentionTombstones();
    if (tombstones.isEmpty) {
      return segments;
    }

    final byId = {for (final segment in segments) segment.id: segment};
    final remaining = <_RetentionTombstone>[];
    var changed = false;

    for (final tombstone in tombstones) {
      try {
        await _deleteArtifactPaths(tombstone.artifactPaths);
      } catch (error) {
        final segment = byId[tombstone.segmentId];
        if (segment != null) {
          byId[tombstone.segmentId] = segment.copyWith(
            error: 'Local retention recovery failed: $error',
          );
          changed = true;
        }
        remaining.add(tombstone);
        continue;
      }

      final segment = byId[tombstone.segmentId];
      if (segment != null) {
        byId[tombstone.segmentId] = _applyTombstone(segment, tombstone);
        changed = true;
      }
      await _removeArtifactInventoryEntry(tombstone.segmentId);
    }

    final reconciled = segments
        .map((segment) => byId[segment.id] ?? segment)
        .toList();
    if (changed) {
      await saveSegments(reconciled);
    }
    await _saveRetentionTombstones(remaining);
    return reconciled;
  }

  Future<void> _putRetentionTombstone(_RetentionTombstone tombstone) async {
    final tombstones = await _readRetentionTombstones();
    final updated =
        tombstones
            .where((entry) => entry.segmentId != tombstone.segmentId)
            .toList()
          ..add(tombstone);
    await _saveRetentionTombstones(updated);
  }

  Future<void> _completeRetentionTombstones(
    List<_RetentionTombstone> completed,
  ) async {
    if (completed.isEmpty) {
      return;
    }
    final completedIds = completed.map((entry) => entry.segmentId).toSet();
    final remaining = (await _readRetentionTombstones())
        .where((entry) => !completedIds.contains(entry.segmentId))
        .toList();
    for (final segmentId in completedIds) {
      await _removeArtifactInventoryEntry(segmentId);
    }
    await _saveRetentionTombstones(remaining);
  }

  Future<List<_RetentionTombstone>> _readRetentionTombstones() async {
    final file = await _retentionTombstoneFile;
    if (!await file.exists()) {
      return [];
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return [];
    }
    try {
      final json = jsonDecode(raw) as List<dynamic>;
      return json
          .cast<Map<String, dynamic>>()
          .map(_RetentionTombstone.fromJson)
          .toList();
    } catch (error) {
      throw StateError('Retention tombstone journal is corrupt: $error');
    }
  }

  Future<void> _saveRetentionTombstones(
    List<_RetentionTombstone> tombstones,
  ) async {
    final file = await _retentionTombstoneFile;
    if (tombstones.isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    tombstones.sort((a, b) => a.segmentId.compareTo(b.segmentId));
    await _atomicWriteJson(
      file,
      tombstones.map((entry) => entry.toJson()).toList(),
    );
  }

  Future<Map<String, List<String>>> _readArtifactInventory() async {
    final file = await _artifactInventoryFile;
    if (!await file.exists()) {
      return {};
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return {};
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json.map(
        (segmentId, value) => MapEntry(
          segmentId,
          (value as List<dynamic>)
              .whereType<String>()
              .map(p.normalize)
              .toList(),
        ),
      );
    } catch (error) {
      throw StateError('Local artifact inventory is corrupt: $error');
    }
  }

  Future<void> _saveArtifactInventory(
    Map<String, List<String>> inventory,
  ) async {
    final file = await _artifactInventoryFile;
    if (inventory.isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    final sorted = <String, List<String>>{};
    for (final segmentId in inventory.keys.toList()..sort()) {
      sorted[segmentId] = [...inventory[segmentId]!]..sort();
    }
    await _atomicWriteJson(file, sorted);
  }

  Future<void> _removeArtifactInventoryEntry(String segmentId) async {
    final inventory = await _readArtifactInventory();
    if (inventory.remove(segmentId) != null) {
      await _saveArtifactInventory(inventory);
    }
  }

  Future<void> _notifyMutation(
    RetentionMutationStage stage,
    String segmentId,
  ) async {
    final hook = _retentionMutationHook;
    if (hook != null) {
      await hook(stage, segmentId);
    }
  }

  static String _spectralSidecarPath(String audioPath) {
    final dot = audioPath.lastIndexOf('.');
    final stem = dot < 0 ? audioPath : audioPath.substring(0, dot);
    return '$stem.features.json';
  }

  Future<void> _atomicWriteJson(File file, Object value) async {
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    await tempFile.rename(file.path);
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

class _RetentionTombstone {
  const _RetentionTombstone({
    required this.segmentId,
    required this.reason,
    required this.cutoffUtc,
    required this.expiredBeforeBackup,
    required this.artifactPaths,
  });

  final String segmentId;
  final _LocalDeletionReason reason;
  final DateTime cutoffUtc;
  final bool expiredBeforeBackup;
  final List<String> artifactPaths;

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'segmentId': segmentId,
      'reason': reason.name,
      'cutoffUtc': cutoffUtc.toUtc().toIso8601String(),
      'expiredBeforeBackup': expiredBeforeBackup,
      'artifactPaths': artifactPaths,
    };
  }

  factory _RetentionTombstone.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('unsupported tombstone version');
    }
    final reasonName = json['reason'] as String?;
    final reason = _LocalDeletionReason.values.firstWhere(
      (value) => value.name == reasonName,
      orElse: () => throw FormatException(
        'unsupported local deletion reason $reasonName',
      ),
    );
    final artifactPaths = (json['artifactPaths'] as List<dynamic>)
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toList();
    if (artifactPaths.isEmpty) {
      throw const FormatException('tombstone has no artifact paths');
    }
    return _RetentionTombstone(
      segmentId: json['segmentId'] as String,
      reason: reason,
      cutoffUtc: DateTime.parse(json['cutoffUtc'] as String).toUtc(),
      expiredBeforeBackup: json['expiredBeforeBackup'] as bool? ?? false,
      artifactPaths: artifactPaths,
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
