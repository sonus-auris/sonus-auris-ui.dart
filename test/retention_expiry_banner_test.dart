import 'package:audio_dashcam/src/models/local_retention_warning.dart';
import 'package:audio_dashcam/src/models/recording_segment.dart';
import 'package:audio_dashcam/src/widgets/retention_expiry_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders nothing when no local copy is at risk', (tester) async {
    await tester.pumpWidget(
      _app(warnings: const [], nowUtc: DateTime.utc(2026, 7, 27, 12)),
    );

    expect(find.text('Local copy nearing automatic deletion'), findsNothing);
    expect(find.text('Retry backup'), findsNothing);
  });

  testWidgets('shows earliest exact deadline, count, and safe actions', (
    tester,
  ) async {
    var retries = 0;
    var exportedSegmentId = '';
    var cleanups = 0;
    final now = DateTime.utc(2026, 7, 27, 12);
    final warnings = [
      _warning(id: 'later', expiresAtUtc: now.add(const Duration(hours: 6))),
      _warning(id: 'earliest', expiresAtUtc: now.add(const Duration(hours: 2))),
    ];

    await tester.pumpWidget(
      _app(
        warnings: warnings,
        nowUtc: now,
        onRetry: () async => retries += 1,
        onExport: (id) async => exportedSegmentId = id,
        onCleanup: () async => cleanups += 1,
      ),
    );

    expect(find.text('Local copy nearing automatic deletion'), findsOneWidget);
    expect(find.text('2 local copies are affected.'), findsOneWidget);
    expect(find.textContaining('2026-07-27T14:00:00.000Z'), findsOneWidget);
    expect(
      find.textContaining('outside Sonus Auris automatic retention'),
      findsOneWidget,
    );
    expect(cleanups, 0);

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(
        RegExp(
          'Local copy nearing automatic deletion.*Exact UTC deadline 2026-07-27T14:00:00.000Z',
        ),
      ),
      findsOneWidget,
    );
    semantics.dispose();

    await tester.tap(find.text('Retry backup'));
    await tester.pump();
    expect(retries, 1);

    await tester.tap(find.text('Export local copy'));
    await tester.pump();
    expect(exportedSegmentId, 'earliest');
  });

  testWidgets('overdue plaintext is a health defect and schedules cleanup', (
    tester,
  ) async {
    var cleanups = 0;
    final now = DateTime.utc(2026, 7, 27, 12);
    final warning = _warning(
      id: 'overdue',
      expiresAtUtc: now.subtract(const Duration(minutes: 1)),
    );

    await tester.pumpWidget(
      _app(
        warnings: [warning],
        nowUtc: now,
        onCleanup: () async => cleanups += 1,
      ),
    );
    await tester.pump();

    expect(find.text('Privacy cleanup overdue'), findsOneWidget);
    expect(
      find.textContaining('crossed the app-private deletion deadline'),
      findsOneWidget,
    );
    expect(find.text('Run cleanup again'), findsOneWidget);
    expect(cleanups, 1);

    // Rebuilding the same overdue state does not create a cleanup loop.
    await tester.pumpWidget(
      _app(
        warnings: [warning],
        nowUtc: now.add(const Duration(seconds: 1)),
        onCleanup: () async => cleanups += 1,
      ),
    );
    await tester.pump();
    expect(cleanups, 1);

    await tester.tap(find.text('Run cleanup again'));
    await tester.pump();
    expect(cleanups, 2);
  });

  testWidgets('materially changed overdue deadline triggers cleanup again', (
    tester,
  ) async {
    var cleanups = 0;
    final now = DateTime.utc(2026, 7, 27, 12);

    await tester.pumpWidget(
      _app(
        warnings: [
          _warning(
            id: 'segment-a',
            expiresAtUtc: now.subtract(const Duration(minutes: 2)),
          ),
        ],
        nowUtc: now,
        onCleanup: () async => cleanups += 1,
      ),
    );
    await tester.pump();
    expect(cleanups, 1);

    await tester.pumpWidget(
      _app(
        warnings: [
          _warning(
            id: 'segment-b',
            expiresAtUtc: now.subtract(const Duration(minutes: 1)),
          ),
        ],
        nowUtc: now,
        onCleanup: () async => cleanups += 1,
      ),
    );
    await tester.pump();
    expect(cleanups, 2);
  });
}

Widget _app({
  required List<LocalRetentionWarning> warnings,
  required DateTime nowUtc,
  Future<void> Function()? onRetry,
  Future<void> Function(String)? onExport,
  Future<void> Function()? onCleanup,
}) => MaterialApp(
  home: Scaffold(
    body: RetentionExpiryBanner(
      warnings: warnings,
      nowUtc: nowUtc,
      onRetryBackup: onRetry ?? () async {},
      onExportLocalCopy: onExport ?? (_) async {},
      onRunCleanup: onCleanup ?? () async {},
    ),
  ),
);

LocalRetentionWarning _warning({
  required String id,
  required DateTime expiresAtUtc,
}) => LocalRetentionWarning(
  segmentId: id,
  expiresAtUtc: expiresAtUtc,
  byteSize: 1920000,
  uploadStatus: SegmentUploadStatus.failed,
);
