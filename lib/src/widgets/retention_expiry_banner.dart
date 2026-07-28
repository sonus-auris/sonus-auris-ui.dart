import 'dart:async';

import 'package:flutter/material.dart';

import '../models/local_retention_warning.dart';

/// Prominent, content-free warning for app-private plaintext that is nearing or
/// has crossed its non-bypassable deletion deadline.
///
/// The banner never receives a path, remote object name, provider error, token,
/// transcript, audio payload, or key. Export is an explicit user-controlled copy
/// outside automatic app retention and does not move the app-private deadline.
class RetentionExpiryBanner extends StatefulWidget {
  const RetentionExpiryBanner({
    super.key,
    required this.warnings,
    required this.nowUtc,
    required this.onRetryBackup,
    required this.onExportLocalCopy,
    required this.onRunCleanup,
  });

  final List<LocalRetentionWarning> warnings;
  final DateTime nowUtc;
  final Future<void> Function() onRetryBackup;
  final Future<void> Function(String segmentId) onExportLocalCopy;
  final Future<void> Function() onRunCleanup;

  @override
  State<RetentionExpiryBanner> createState() => _RetentionExpiryBannerState();
}

class _RetentionExpiryBannerState extends State<RetentionExpiryBanner> {
  String? _lastAutomaticCleanupSignature;

  @override
  void initState() {
    super.initState();
    _scheduleCleanupForOverduePlaintext();
  }

  @override
  void didUpdateWidget(covariant RetentionExpiryBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleCleanupForOverduePlaintext();
  }

  void _scheduleCleanupForOverduePlaintext() {
    final now = widget.nowUtc.toUtc();
    final overdue = widget.warnings
        .where((warning) => warning.isOverdueAt(now))
        .toList(growable: false)
      ..sort((left, right) {
        final byDeadline = left.expiresAtUtc.compareTo(right.expiresAtUtc);
        return byDeadline != 0
            ? byDeadline
            : left.segmentId.compareTo(right.segmentId);
      });
    if (overdue.isEmpty) {
      _lastAutomaticCleanupSignature = null;
      return;
    }
    final signature = overdue
        .map(
          (warning) =>
              '${warning.segmentId}:${warning.expiresAtUtc.toUtc().toIso8601String()}',
        )
        .join('|');
    if (signature == _lastAutomaticCleanupSignature) {
      return;
    }
    _lastAutomaticCleanupSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.onRunCleanup());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.warnings.isEmpty) {
      return const SizedBox.shrink();
    }

    final now = widget.nowUtc.toUtc();
    final warnings = [...widget.warnings]
      ..sort((left, right) {
        final byDeadline = left.expiresAtUtc.compareTo(right.expiresAtUtc);
        return byDeadline != 0
            ? byDeadline
            : left.segmentId.compareTo(right.segmentId);
      });
    final earliest = warnings.first;
    final overdueCount = warnings
        .where((warning) => warning.isOverdueAt(now))
        .length;
    final isOverdue = overdueCount > 0;
    final scheme = Theme.of(context).colorScheme;
    final localDeadline = _formatLocalDeadline(context, earliest.expiresAtUtc);
    final utcDeadline = earliest.expiresAtUtc.toUtc().toIso8601String();
    final affectedLabel = warnings.length == 1
        ? '1 local copy is affected.'
        : '${warnings.length} local copies are affected.';
    final title = isOverdue
        ? 'Privacy cleanup overdue'
        : 'Local copy nearing automatic deletion';
    final deadlineCopy = isOverdue
        ? '$overdueCount local ${overdueCount == 1 ? 'copy has' : 'copies have'} crossed the app-private deletion deadline. Cleanup is running now.'
        : 'Backup has not completed. The earliest local copy will be deleted at $localDeadline.';
    final semanticsLabel =
        '$title. $deadlineCopy $affectedLabel Exact UTC deadline $utcDeadline. '
        'Retrying backup or exporting a user-controlled copy does not extend the app-private deadline.';

    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isOverdue ? scheme.errorContainer : scheme.tertiaryContainer,
          border: Border.all(
            color: isOverdue ? scheme.error : scheme.tertiary,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    isOverdue
                        ? Icons.privacy_tip
                        : Icons.schedule_outlined,
                    color: isOverdue
                        ? scheme.onErrorContainer
                        : scheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: isOverdue
                                ? scheme.onErrorContainer
                                : scheme.onTertiaryContainer,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(deadlineCopy),
                        const SizedBox(height: 4),
                        Text(affectedLabel),
                        const SizedBox(height: 4),
                        SelectableText(
                          'UTC: $utcDeadline',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Exporting creates a user-controlled copy outside Sonus Auris automatic retention. It does not delay deletion of the app-private copy.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => unawaited(widget.onRetryBackup()),
                    icon: const Icon(Icons.cloud_sync_outlined),
                    label: const Text('Retry backup'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      widget.onExportLocalCopy(earliest.segmentId),
                    ),
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('Export local copy'),
                  ),
                  if (isOverdue)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(widget.onRunCleanup()),
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: const Text('Run cleanup again'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatLocalDeadline(BuildContext context, DateTime deadlineUtc) {
    final local = deadlineUtc.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatMediumDate(local);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '$date at $time';
  }
}
