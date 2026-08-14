import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart' show getSaveLocation;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../models/recording_segment.dart';
import '../platform/runtime_platform.dart';

enum LocalExportStatus {
  completed,
  presented,
  cancelled,
  sourceMissing,
  unsupported,
  failed,
}

enum LocalExportPlatform { mobileShare, desktopSave, unsupported }

class LocalExportResult {
  const LocalExportResult(this.status, this.message);

  final LocalExportStatus status;
  final String message;

  bool get succeeded =>
      status == LocalExportStatus.completed ||
      status == LocalExportStatus.presented;
}

typedef LocalFileExists = Future<bool> Function(String sourcePath);
typedef LocalFileSharer =
    Future<ShareResultStatus> Function({
      required String sourcePath,
      required String suggestedName,
      required String contentType,
    });
typedef LocalSavePathPicker =
    Future<String?> Function({required String suggestedName});
typedef LocalPathCanonicalizer = Future<String> Function(String path);
typedef LocalFileCopier =
    Future<void> Function({
      required String sourcePath,
      required String destinationPath,
      required String contentType,
      required String suggestedName,
    });

/// Copies one existing local recording into a destination explicitly selected by
/// the user. The exported copy is outside Sonus Auris automatic retention; this
/// service deliberately does not mutate the segment, its deadline, or its upload
/// state.
///
/// Only a sanitized outcome leaves this service. Source paths, destination paths,
/// provider details, and platform exception text are never returned to the UI or
/// diagnostics.
class LocalExportService {
  LocalExportService({
    LocalExportPlatform? platform,
    LocalFileExists? fileExists,
    LocalFileSharer? shareFile,
    LocalSavePathPicker? pickSavePath,
    LocalPathCanonicalizer? canonicalizePath,
    LocalFileCopier? copyFile,
  }) : platform = platform ?? _detectPlatform(),
       _fileExists = fileExists ?? _defaultFileExists,
       _shareFile = shareFile ?? _defaultShareFile,
       _pickSavePath = pickSavePath ?? _defaultPickSavePath,
       _canonicalizePath = canonicalizePath ?? _defaultCanonicalizePath,
       _copyFile = copyFile ?? _defaultCopyFile;

  final LocalExportPlatform platform;
  final LocalFileExists _fileExists;
  final LocalFileSharer _shareFile;
  final LocalSavePathPicker _pickSavePath;
  final LocalPathCanonicalizer _canonicalizePath;
  final LocalFileCopier _copyFile;

  Future<LocalExportResult> exportSegment(RecordingSegment segment) async {
    final sourcePath = segment.localPath?.trim() ?? '';
    if (sourcePath.isEmpty || !await _fileExists(sourcePath)) {
      return const LocalExportResult(
        LocalExportStatus.sourceMissing,
        'This local copy is no longer available to export.',
      );
    }

    final suggestedName = _suggestedName(segment);
    try {
      switch (platform) {
        case LocalExportPlatform.mobileShare:
          final result = await _shareFile(
            sourcePath: sourcePath,
            suggestedName: suggestedName,
            contentType: segment.contentType,
          );
          return switch (result) {
            ShareResultStatus.success => const LocalExportResult(
              LocalExportStatus.completed,
              'Export completed. The user-controlled copy is outside Sonus Auris automatic retention.',
            ),
            ShareResultStatus.dismissed => const LocalExportResult(
              LocalExportStatus.cancelled,
              'Local export was cancelled. The app-private deletion deadline did not change.',
            ),
            ShareResultStatus.unavailable => const LocalExportResult(
              LocalExportStatus.presented,
              'The system share sheet opened. Any copy saved from it is outside Sonus Auris automatic retention.',
            ),
          };
        case LocalExportPlatform.desktopSave:
          final destinationPath = await _pickSavePath(
            suggestedName: suggestedName,
          );
          if (destinationPath == null || destinationPath.trim().isEmpty) {
            return const LocalExportResult(
              LocalExportStatus.cancelled,
              'Local export was cancelled. The app-private deletion deadline did not change.',
            );
          }
          if (await _isAppPrivateDestination(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
          )) {
            return const LocalExportResult(
              LocalExportStatus.failed,
              'Choose a destination outside Sonus Auris app storage. The retention deadline did not change.',
            );
          }
          await _copyFile(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            contentType: segment.contentType,
            suggestedName: suggestedName,
          );
          return const LocalExportResult(
            LocalExportStatus.completed,
            'Export completed. The user-controlled copy is outside Sonus Auris automatic retention.',
          );
        case LocalExportPlatform.unsupported:
          return const LocalExportResult(
            LocalExportStatus.unsupported,
            'Local export is not available on this platform. The retention deadline did not change.',
          );
      }
    } catch (_) {
      return const LocalExportResult(
        LocalExportStatus.failed,
        'Local export failed. The app-private retention deadline did not change.',
      );
    }
  }

  static LocalExportPlatform _detectPlatform() {
    if (RuntimePlatform.isAndroid || RuntimePlatform.isIOS) {
      return LocalExportPlatform.mobileShare;
    }
    if (RuntimePlatform.isLinux ||
        RuntimePlatform.isMacOS ||
        RuntimePlatform.isWindows) {
      return LocalExportPlatform.desktopSave;
    }
    return LocalExportPlatform.unsupported;
  }

  static Future<bool> _defaultFileExists(String sourcePath) =>
      File(sourcePath).exists();

  static Future<ShareResultStatus> _defaultShareFile({
    required String sourcePath,
    required String suggestedName,
    required String contentType,
  }) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        title: 'Export Sonus Auris local copy',
        text:
            'This exported copy is controlled by you and is outside Sonus Auris automatic retention.',
        files: [XFile(sourcePath, mimeType: contentType, name: suggestedName)],
        fileNameOverrides: [suggestedName],
        // iPad requires a non-empty popover origin. Computing it from the active
        // logical view avoids passing widget geometry into the controller layer.
        sharePositionOrigin: _defaultSharePositionOrigin(),
      ),
    );
    return result.status;
  }

  static Rect? _defaultSharePositionOrigin() {
    if (!RuntimePlatform.isIOS) {
      return null;
    }
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    final view = views.first;
    final ratio = view.devicePixelRatio == 0 ? 1.0 : view.devicePixelRatio;
    final width = view.physicalSize.width / ratio;
    final height = view.physicalSize.height / ratio;
    return Rect.fromLTWH(width / 2, height / 2, 1, 1);
  }

  static Future<String?> _defaultPickSavePath({
    required String suggestedName,
  }) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      confirmButtonText: 'Export',
      canCreateDirectories: true,
    );
    return location?.path;
  }

  static Future<void> _defaultCopyFile({
    required String sourcePath,
    required String destinationPath,
    required String contentType,
    required String suggestedName,
  }) => XFile(
    sourcePath,
    mimeType: contentType,
    name: suggestedName,
  ).saveTo(destinationPath);

  Future<bool> _isAppPrivateDestination({
    required String sourcePath,
    required String destinationPath,
  }) async {
    final source = p.normalize(await _canonicalizePath(sourcePath));
    final destination = p.normalize(await _canonicalizePath(destinationPath));
    if (p.equals(source, destination)) {
      return true;
    }

    final sourceParent = p.dirname(source);
    if (p.equals(sourceParent, destination) ||
        p.isWithin(sourceParent, destination)) {
      return true;
    }

    final sourceParts = p.split(source);
    final segmentsIndex = sourceParts.lastIndexWhere(
      (part) => part.toLowerCase() == 'segments',
    );
    if (segmentsIndex >= 0) {
      final segmentsRoot = p.joinAll(sourceParts.take(segmentsIndex + 1));
      final appPrivateRoot = p.dirname(segmentsRoot);
      if (p.equals(appPrivateRoot, destination) ||
          p.isWithin(appPrivateRoot, destination)) {
        return true;
      }
    }
    return false;
  }

  static Future<String> _defaultCanonicalizePath(String rawPath) async {
    final absolutePath = File(rawPath).absolute.path;
    try {
      return p.normalize(await File(absolutePath).resolveSymbolicLinks());
    } on FileSystemException {
      final resolvedParent = await Directory(
        p.dirname(absolutePath),
      ).resolveSymbolicLinks();
      return p.normalize(p.join(resolvedParent, p.basename(absolutePath)));
    }
  }

  static String _suggestedName(RecordingSegment segment) {
    final timestamp = segment.endedAtUtc.toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final extension = segment.fileExtension.trim().isEmpty
        ? 'audio'
        : segment.fileExtension.trim().toLowerCase();
    return 'sonus-auris-$timestamp.$extension';
  }
}
