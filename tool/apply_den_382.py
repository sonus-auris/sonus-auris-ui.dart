#!/usr/bin/env python3
"""One-time exact patch for DEN-382 controller and Home-view integration."""

from pathlib import Path


def replace(path: str, old: str, new: str, count: int = 1) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    actual = text.count(old)
    if actual != count:
        raise SystemExit(
            f"{path}: expected {count} occurrence(s), found {actual}: {old!r}"
        )
    file.write_text(text.replace(old, new), encoding="utf-8")


def patch_controller() -> None:
    path = "lib/src/app/app_controller.dart"
    replace(
        path,
        "import '../services/location_service.dart';\nimport '../services/diagnostic_log.dart';",
        "import '../services/location_service.dart';\nimport '../services/local_export_service.dart';\nimport '../services/diagnostic_log.dart';",
    )
    replace(
        path,
        "import '../services/voice_id/voice_profile_service.dart';\nimport 'app_view_model.dart';",
        "import '../services/voice_id/voice_profile_service.dart';\nimport '../retention/local_retention_policy.dart';\nimport 'app_view_model.dart';",
    )
    replace(
        path,
        "    RecordingFeedback? feedback,\n    LocationService? locationService,\n    PowerNetworkGate? powerNetworkGate,",
        "    RecordingFeedback? feedback,\n    LocationService? locationService,\n    LocalExportService? localExportService,\n    PowerNetworkGate? powerNetworkGate,",
    )
    replace(
        path,
        "      feedback: feedback ?? RecordingFeedback(),\n      locationService: locationService ?? LocationService(),\n      powerNetworkGate:",
        "      feedback: feedback ?? RecordingFeedback(),\n      locationService: locationService ?? LocationService(),\n      localExportService: localExportService ?? LocalExportService(),\n      powerNetworkGate:",
    )
    replace(
        path,
        "    required this._feedback,\n    required this._locationService,\n    required this._powerNetworkGate,",
        "    required this._feedback,\n    required this._locationService,\n    required this._localExportService,\n    required this._powerNetworkGate,",
    )
    replace(
        path,
        "  final RecordingFeedback _feedback;\n  final LocationService _locationService;\n  final PowerNetworkGate _powerNetworkGate;",
        "  final RecordingFeedback _feedback;\n  final LocationService _locationService;\n  final LocalExportService _localExportService;\n  final PowerNetworkGate _powerNetworkGate;",
    )
    replace(
        path,
        "    final deviceRetentionHours = config.deviceRetentionHours.clamp(1, 500);",
        "    final deviceRetentionHours = config.deviceRetentionHours\n        .clamp(1, LocalRetentionPolicy.maxPlaintextRetentionHours)\n        .toInt();",
    )
    replace(
        path,
        "  void requestUploadDrain() {\n    if (!_uploadRequests.isClosed) {\n      _uploadRequests.add(null);\n    }\n  }\n\n  Future<void> clearMessage() async {",
        """  void requestUploadDrain() {
    if (!_uploadRequests.isClosed) {
      _uploadRequests.add(null);
    }
  }

  /// Re-evaluates the transfer gate and requests the existing upload drain. This
  /// action never modifies a local plaintext deadline.
  Future<void> retryPendingBackups() async {
    final pending = (_segments.valueOrNull ?? const <RecordingSegment>[])
        .where(
          (segment) =>
              segment.isLocal &&
              (segment.uploadStatus == SegmentUploadStatus.pending ||
                  segment.uploadStatus == SegmentUploadStatus.uploading ||
                  segment.uploadStatus == SegmentUploadStatus.failed),
        )
        .length;
    if (pending == 0) {
      _message.add('No local backups are waiting to retry.');
      return;
    }
    final config = _config.valueOrNull;
    if (config == null || !config.uploadEnabled) {
      _message.add(
        'Backup is disabled. The app-private deletion deadline did not change.',
      );
      return;
    }
    final gate = await _refreshTransferStatus();
    if (!gate.allowed) {
      _message.add(
        'Backup is still paused by the current power or network policy. The deletion deadline did not change.',
      );
      return;
    }
    requestUploadDrain();
    _message.add(
      'Retrying backup for $pending local ${pending == 1 ? 'copy' : 'copies'}. The deletion deadline did not change.',
    );
  }

  /// Runs the existing fail-closed retention cleanup immediately. The user-facing
  /// result is intentionally content-free and never includes paths or provider
  /// details.
  Future<void> runRetentionCleanupNow() async {
    try {
      await _enforceRetention();
      _message.add('Local retention cleanup completed.');
    } catch (_) {
      _diagnostics.add('Manual local retention cleanup failed.');
      _message.add(
        'Privacy cleanup could not complete. Restart Sonus Auris and try again.',
      );
    }
  }

  /// Exports one explicit user-controlled copy without changing the segment's
  /// upload state or app-private retention deadline.
  Future<void> exportLocalCopy(String segmentId) async {
    RecordingSegment? selected;
    for (final segment in _segments.valueOrNull ?? const <RecordingSegment>[]) {
      if (segment.id == segmentId) {
        selected = segment;
        break;
      }
    }
    if (selected == null || !selected.isLocal) {
      _message.add('This local copy is no longer available to export.');
      return;
    }
    final result = await _localExportService.exportSegment(selected);
    _message.add(result.message);
  }

  Future<void> clearMessage() async {""",
    )


def patch_main() -> None:
    path = "lib/main.dart"
    replace(
        path,
        "import 'src/widgets/supabase_auth_form.dart';",
        "import 'src/widgets/supabase_auth_form.dart';\nimport 'src/widgets/retention_expiry_banner.dart';",
    )
    replace(
        path,
        "          onSendAlert: widget.controller.sendManualAlert,\n          onConfirm: widget.controller.confirmRecording,",
        "          onSendAlert: widget.controller.sendManualAlert,\n          onConfirm: widget.controller.confirmRecording,\n          onRetryBackup: widget.controller.retryPendingBackups,\n          onExportLocalCopy: widget.controller.exportLocalCopy,\n          onRunRetentionCleanup: widget.controller.runRetentionCleanupNow,",
    )
    replace(
        path,
        "    required this.onSendAlert,\n    required this.onConfirm,\n  });\n\n  final AppViewModel viewModel;\n  final VoidCallback onStart;\n  final VoidCallback onStop;\n  final VoidCallback onRestart;\n  final VoidCallback onToggleHighQuality;\n  final VoidCallback onSendAlert;\n  final VoidCallback onConfirm;",
        "    required this.onSendAlert,\n    required this.onConfirm,\n    required this.onRetryBackup,\n    required this.onExportLocalCopy,\n    required this.onRunRetentionCleanup,\n  });\n\n  final AppViewModel viewModel;\n  final VoidCallback onStart;\n  final VoidCallback onStop;\n  final VoidCallback onRestart;\n  final VoidCallback onToggleHighQuality;\n  final VoidCallback onSendAlert;\n  final VoidCallback onConfirm;\n  final Future<void> Function() onRetryBackup;\n  final Future<void> Function(String segmentId) onExportLocalCopy;\n  final Future<void> Function() onRunRetentionCleanup;",
    )
    replace(
        path,
        "  @override\n  Widget build(BuildContext context) {\n    return ListView(\n      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),\n      children: [\n        const _PageHeader(\n          eyebrow: 'Overview',",
        "  @override\n  Widget build(BuildContext context) {\n    final nowUtc = DateTime.now().toUtc();\n    final retentionWarnings = viewModel.localRetentionWarnings(nowUtc: nowUtc);\n    return ListView(\n      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),\n      children: [\n        const _PageHeader(\n          eyebrow: 'Overview',",
    )
    replace(
        path,
        "        if (!viewModel.isSignedIn) ...[\n          const _SignInNotice(),\n          const SizedBox(height: 12),\n        ],\n        _StatusSection(",
        "        if (!viewModel.isSignedIn) ...[\n          const _SignInNotice(),\n          const SizedBox(height: 12),\n        ],\n        if (retentionWarnings.isNotEmpty) ...[\n          RetentionExpiryBanner(\n            warnings: retentionWarnings,\n            nowUtc: nowUtc,\n            onRetryBackup: onRetryBackup,\n            onExportLocalCopy: onExportLocalCopy,\n            onRunCleanup: onRunRetentionCleanup,\n          ),\n          const SizedBox(height: 12),\n        ],\n        _StatusSection(",
    )
    replace(
        path,
        "      deviceRetentionHours: _parseInt(_deviceRetentionController.text, 50),",
        "      deviceRetentionHours: _parseInt(_deviceRetentionController.text, 100),",
    )


def patch_segment_index_lint() -> None:
    path = "lib/src/services/segment_index.dart"
    replace(
        path,
        "  }) : _baseDirectoryProvider =\n           baseDirectoryProvider ?? getApplicationSupportDirectory,\n       _retentionMutationHook = retentionMutationHook;",
        "  }) : _baseDirectoryProvider =\n           baseDirectoryProvider ?? getApplicationSupportDirectory,\n       // Preserve the public test-hook parameter name without exposing a private\n       // named argument solely to satisfy the initializing-formal preference.\n       // ignore: prefer_initializing_formals\n       _retentionMutationHook = retentionMutationHook;",
    )


if __name__ == "__main__":
    patch_controller()
    patch_main()
    patch_segment_index_lint()
