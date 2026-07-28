#!/usr/bin/env python3
"""Replace the static Home warning projection with the idle-refresh surface."""

from pathlib import Path


def replace(old: str, new: str) -> None:
    path = Path("lib/main.dart")
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")


replace(
    """  Widget build(BuildContext context) {
    final nowUtc = DateTime.now().toUtc();
    final retentionWarnings = viewModel.localRetentionWarnings(nowUtc: nowUtc);
    return ListView(""",
    """  Widget build(BuildContext context) {
    return ListView(""",
)

replace(
    """        if (retentionWarnings.isNotEmpty) ...[
          RetentionExpiryBanner(
            warnings: retentionWarnings,
            nowUtc: nowUtc,
            onRetryBackup: onRetryBackup,
            onExportLocalCopy: onExportLocalCopy,
            onRunCleanup: onRunRetentionCleanup,
          ),
          const SizedBox(height: 12),
        ],""",
    """        RetentionExpirySurface(
          warningProvider: (nowUtc) =>
              viewModel.localRetentionWarnings(nowUtc: nowUtc),
          onRetryBackup: onRetryBackup,
          onExportLocalCopy: onExportLocalCopy,
          onRunCleanup: onRunRetentionCleanup,
        ),""",
)
