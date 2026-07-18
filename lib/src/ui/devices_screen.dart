// Devices: every install on the account, with the plan's device-limit gate.
// Recorders beyond the limit render locked (viewable after upgrading).
import 'package:flutter/material.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart' as interfaces;

import '../services/console_controller.dart';
import '../util/platform_info.dart';
import '../util/relative_time.dart';
import 'console_home.dart';

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key, required this.controller});

  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.devices;
    final limit = controller.entitlement.deviceLimit;
    final active = controller.activeRecorderCount;
    return ConsolePage(
      title: 'Devices',
      onRefresh: controller.refreshDevicesAndEntitlements,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _UsageBanner(
            active: active,
            limit: limit,
            isPlus: controller.entitlement.isPlus,
          ),
          const SizedBox(height: 12),
          if (devices.isEmpty)
            const _Empty(
              icon: Icons.devices_other,
              text: 'No devices yet. Install the Sonus Auris app on a phone '
                  'and sign in with this account.',
            )
          else
            for (final device in devices)
              _DeviceCard(
                controller: controller,
                device: device,
                locked: controller.lockedDeviceIds.contains(device.deviceId),
              ),
        ],
      ),
    );
  }
}

class _UsageBanner extends StatelessWidget {
  const _UsageBanner({
    required this.active,
    required this.limit,
    required this.isPlus,
  });

  final int active;
  final int limit;
  final bool isPlus;

  @override
  Widget build(BuildContext context) {
    final over = active > limit;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: over ? scheme.errorContainer : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(over ? Icons.lock_outline : Icons.check_circle_outline,
                color: over ? scheme.error : scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                over
                    ? '$active recorders on a plan for $limit. The oldest are '
                        'locked — upgrade to view them all.'
                    : '$active of $limit recorder devices used'
                        '${isPlus ? ' (Plus)' : ''}.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.controller,
    required this.device,
    required this.locked,
  });

  final ConsoleController controller;
  final interfaces.DeviceRecord device;
  final bool locked;

  bool get _revoked => (device.revokedAt ?? '').trim().isNotEmpty;
  bool get _isViewer => device.role.trim().toLowerCase() == 'viewer';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Opacity(
        opacity: locked || _revoked ? 0.6 : 1,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: Icon(_platformIcon(device.platform)),
          title: Row(
            children: [
              Flexible(child: Text(device.displayName)),
              const SizedBox(width: 8),
              _Badge(_isViewer ? 'This console' : 'Recorder',
                  color: _isViewer ? scheme.tertiary : scheme.primary),
              if (locked) ...[
                const SizedBox(width: 6),
                _Badge('Locked', color: scheme.error, icon: Icons.lock),
              ],
              if (_revoked) ...[
                const SizedBox(width: 6),
                _Badge('Removed', color: scheme.outline),
              ],
            ],
          ),
          subtitle: Text(
            '${platformLabel(device.platform)} · seen ${relativeTimeIso(device.lastSeenAt)}',
          ),
          trailing: _isViewer
              ? null
              : PopupMenuButton<String>(
                  onSelected: (v) => _onAction(context, v),
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(
                      value: 'revoke',
                      child: Text(_revoked ? 'Restore' : 'Remove from account'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, String action) async {
    switch (action) {
      case 'rename':
        final name = await _promptName(context, device.displayName);
        if (name != null && name.trim().isNotEmpty) {
          await controller.renameDevice(device.deviceId, name.trim());
        }
      case 'revoke':
        await controller.setDeviceRevoked(device.deviceId, !_revoked);
      case 'delete':
        final ok = await _confirmDelete(context, device.displayName);
        if (ok) {
          await controller.removeDevice(device.deviceId);
        }
    }
  }

  Future<String?> _promptName(BuildContext context, String current) {
    final field = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text(
          'This removes the device row. The device re-registers itself the '
          'next time it signs in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

IconData _platformIcon(String platform) {
  switch (platform.trim().toLowerCase()) {
    case 'android':
    case 'ios':
      return Icons.smartphone;
    case 'macos':
    case 'windows':
    case 'linux':
      return Icons.computer;
    case 'web':
      return Icons.public;
    default:
      return Icons.devices_other;
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, {required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
