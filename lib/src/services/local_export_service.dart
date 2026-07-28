import 'dart:io';

import 'package:file_selector/file_selector.dart' show getSaveLocation;
import 'package:share_plus/share_plus.dart';

import '../models/recording_segment.dart';

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
typedef LocalFileSharer = Future<ShareResultStatus> Function({
  required String sourcePath,
  required String suggestedName,
  required String contentType,
});
typedef LocalSavePathPicker = Future<String?> Function({
  required String suggestedName,
});
typedef LocalFileCopier = Future<void> Function({
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
    LocalFileCopier? copyFile,
  }) : platform = platform ?? _detectPlatform(),
       _fileExists = fileExists ?? _defaultFileExists,
       _shareFile = shareFile ?? _defaultShareFile,
       _pickSavePath = pickSavePath ?? _defaultPickSavePath,
       _copyFile = copyFile ?? _defaultCopyFile;

  final LocalExportPlatform platform;
  final LocalFileExists _fileExists;
  final LocalFileSharer _shareFile;
  final LocalSavePathPicker _pickSavePath;
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
          if (File(destinationPath).absolute.path == File(sourcePath).absolute.path) {
            return const LocalExportResult(
              LocalExportStatus.failed,
              'Choose a different destination for the exported copy. The retention deadline did not change.',
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
    if (Platform.isAndroid || Platform.isIOS) {
      return LocalExportPlatform.mobileShare;
    }
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
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
      ),
    );
    return result.status;
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

  static String _suggestedName(RecordingSegment segment) {
    final timestamp = segment.endedAtUtc
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final extension = segment.fileExtension.trim().isEmpty
        ? 'audio'
        : segment.fileExtension.trim().toLowerCase();
    return 'sonus-auris-$timestamp.$extension';
  }
}
