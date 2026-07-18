// Billing: the current plan, device usage, and the Plus upgrade path.
//
// PAYMENT COMPLIANCE: this app takes payment via Stripe Checkout ONLY on
// web/desktop distributions. Native iOS/Android store binaries may not use an
// external payment path for digital goods (Apple 3.1.1 / Google Play Payments),
// so on those [isNativeMobileStoreBinary] we hide the Stripe path and point the
// user to the mobile app's in-app purchase (or the web console). Entitlements
// are written server-side by the Stripe webhook — never by this client.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/console_controller.dart';
import '../util/checkout_link.dart';
import '../util/platform_info.dart';
import '../util/relative_time.dart';
import 'console_home.dart';

class BillingScreen extends StatelessWidget {
  const BillingScreen({super.key, required this.controller});

  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final entitlement = controller.entitlement;
    final scheme = Theme.of(context).colorScheme;
    return ConsolePage(
      title: 'Billing',
      onRefresh: controller.refreshDevicesAndEntitlements,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        entitlement.isPlus
                            ? Icons.workspace_premium
                            : Icons.card_membership_outlined,
                        color: entitlement.isPlus ? scheme.tertiary : scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        entitlement.isPlus ? 'Sonus Auris Plus' : 'Free plan',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(entitlement.isPlus
                      ? 'Up to ${entitlement.deviceLimit} devices.'
                          '${entitlement.currentPeriodEnd != null ? ' Renews ${formatStamp(entitlement.currentPeriodEnd!)}.' : ''}'
                      : '2 devices included. Upgrade to Plus to control 3 or more '
                          'devices and unlock permanent saves.'),
                  const SizedBox(height: 12),
                  _UsageMeter(
                    used: controller.activeRecorderCount,
                    limit: entitlement.deviceLimit,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _UpgradeSection(controller: controller),
        ],
      ),
    );
  }
}

class _UsageMeter extends StatelessWidget {
  const _UsageMeter({required this.used, required this.limit});
  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final fraction = limit <= 0 ? 1.0 : (used / limit).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$used of $limit devices used'),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(value: fraction, minHeight: 8),
        ),
      ],
    );
  }
}

class _UpgradeSection extends StatelessWidget {
  const _UpgradeSection({required this.controller});
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    // Native store binaries must not use the external Stripe path.
    if (isNativeMobileStoreBinary) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Manage your plan in the Sonus Auris mobile app or on the web '
            'console at sonusauris.app.',
          ),
        ),
      );
    }

    if (controller.entitlement.isPlus) {
      return const SizedBox.shrink();
    }

    final link = controller.config.stripePaymentLink.trim();
    final configured = link.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Upgrade to Plus',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '· Control 3 or more devices\n'
              '· Permanent cloud saves\n'
              'Your plan activates once payment is confirmed.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: configured ? () => _upgrade(context) : null,
              icon: const Icon(Icons.open_in_new),
              label: Text(configured ? 'Upgrade with Stripe' : 'Payments not configured'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _upgrade(BuildContext context) async {
    final uri = buildCheckoutUri(
      paymentLink: controller.config.stripePaymentLink,
      userId: controller.userId,
      email: controller.email,
    );
    final messenger = ScaffoldMessenger.of(context);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the checkout page.')),
      );
    }
  }
}
