import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/services/local_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  group('LocalExportService', () {
    test(
      'copies to an explicit desktop destination without exposing paths',
      () async {
        String? copiedFrom;
        String? copiedTo;
        String? copiedName;
        final service = LocalExportService(
          platform: LocalExportPlatform.desktopSave,
          fileExists: (_) async => true,
          pickSavePath: ({required suggestedName}) async {
            expect(suggestedName, 'sonus-auris-2026-07-27T12-00-00-000Z.wav');
            return '/user-selected/export.wav';
          },
          copyFile:
              ({
                required sourcePath,
                required destinationPath,
                required contentType,
                required suggestedName,
              }) async {
                copiedFrom = sourcePath;
                copiedTo = destinationPath;
                copiedName = suggestedName;
                expect(contentType, 'audio/wav');
              },
        );

        final result = await service.exportSegment(_segment());

        expect(result.status, LocalExportStatus.completed);
        expect(result.succeeded, isTrue);
        expect(copiedFrom, '/app-private/segment.wav');
        expect(copiedTo, '/user-selected/export.wav');
        expect(copiedName, 'sonus-auris-2026-07-27T12-00-00-000Z.wav');
        expect(
          result.message,
          contains('outside Sonus Auris automatic retention'),
        );
        expect(result.message, isNot(contains('/app-private')));
        expect(result.message, isNot(contains('/user-selected')));
      },
    );

    test('rejects a desktop destination inside app-private storage', () async {
      var copied = false;
      final service = LocalExportService(
        platform: LocalExportPlatform.desktopSave,
        fileExists: (_) async => true,
        pickSavePath: ({required suggestedName}) async =>
            '/app-private/export.wav',
        copyFile:
            ({
              required sourcePath,
              required destinationPath,
              required contentType,
              required suggestedName,
            }) async {
              copied = true;
            },
      );

      final result = await service.exportSegment(_segment());
      expect(result.status, LocalExportStatus.failed);
      expect(copied, isFalse);
      expect(result.message, contains('outside Sonus Auris app storage'));
      expect(result.message, contains('deadline did not change'));
      expect(result.message, isNot(contains('/app-private')));
    });

    test('mobile share success creates a user-controlled copy', () async {
      final service = LocalExportService(
        platform: LocalExportPlatform.mobileShare,
        fileExists: (_) async => true,
        shareFile:
            ({
              required sourcePath,
              required suggestedName,
              required contentType,
            }) async {
              expect(sourcePath, '/app-private/segment.wav');
              expect(suggestedName, endsWith('.wav'));
              expect(contentType, 'audio/wav');
              return ShareResultStatus.success;
            },
      );

      final result = await service.exportSegment(_segment());
      expect(result.status, LocalExportStatus.completed);
      expect(result.succeeded, isTrue);
    });

    test(
      'mobile share dismissal does not claim an export or move retention',
      () async {
        final service = LocalExportService(
          platform: LocalExportPlatform.mobileShare,
          fileExists: (_) async => true,
          shareFile:
              ({
                required sourcePath,
                required suggestedName,
                required contentType,
              }) async => ShareResultStatus.dismissed,
        );

        final result = await service.exportSegment(_segment());
        expect(result.status, LocalExportStatus.cancelled);
        expect(result.succeeded, isFalse);
        expect(result.message, contains('deadline did not change'));
      },
    );

    test(
      'unreported share result is presented without claiming saved output',
      () async {
        final service = LocalExportService(
          platform: LocalExportPlatform.mobileShare,
          fileExists: (_) async => true,
          shareFile:
              ({
                required sourcePath,
                required suggestedName,
                required contentType,
              }) async => ShareResultStatus.unavailable,
        );

        final result = await service.exportSegment(_segment());
        expect(result.status, LocalExportStatus.presented);
        expect(result.message, contains('system share sheet opened'));
        expect(result.message, isNot(contains('Export completed')));
      },
    );

    test(
      'missing local source fails before any picker or share action',
      () async {
        var invoked = false;
        final service = LocalExportService(
          platform: LocalExportPlatform.desktopSave,
          fileExists: (_) async => false,
          pickSavePath: ({required suggestedName}) async {
            invoked = true;
            return '/should-not-be-used';
          },
        );

        final result = await service.exportSegment(_segment());
        expect(result.status, LocalExportStatus.sourceMissing);
        expect(invoked, isFalse);
        expect(result.message, isNot(contains('/app-private')));
      },
    );

    test('cancel and copy failure stay sanitized', () async {
      final cancelled = LocalExportService(
        platform: LocalExportPlatform.desktopSave,
        fileExists: (_) async => true,
        pickSavePath: ({required suggestedName}) async => null,
      );
      expect(
        (await cancelled.exportSegment(_segment())).status,
        LocalExportStatus.cancelled,
      );

      final failed = LocalExportService(
        platform: LocalExportPlatform.desktopSave,
        fileExists: (_) async => true,
        pickSavePath: ({required suggestedName}) async => '/target/export.wav',
        copyFile:
            ({
              required sourcePath,
              required destinationPath,
              required contentType,
              required suggestedName,
            }) async {
              throw StateError('sensitive /target/export.wav provider detail');
            },
      );
      final result = await failed.exportSegment(_segment());
      expect(result.status, LocalExportStatus.failed);
      expect(result.message, contains('retention deadline did not change'));
      expect(result.message, isNot(contains('/target')));
      expect(result.message, isNot(contains('provider detail')));
    });

    test('unsupported platform is explicit and content-free', () async {
      final service = LocalExportService(
        platform: LocalExportPlatform.unsupported,
        fileExists: (_) async => true,
      );
      final result = await service.exportSegment(_segment());
      expect(result.status, LocalExportStatus.unsupported);
      expect(result.succeeded, isFalse);
      expect(result.message, contains('not available on this platform'));
      expect(result.message, isNot(contains('/app-private')));
    });
  });
}

RecordingSegment _segment() => RecordingSegment(
  id: 'segment-a',
  startedAtUtc: DateTime.utc(2026, 7, 27, 11, 59),
  endedAtUtc: DateTime.utc(2026, 7, 27, 12),
  localPath: '/app-private/segment.wav',
  byteSize: 1920000,
  uploadStatus: SegmentUploadStatus.failed,
  container: 'wav',
);
