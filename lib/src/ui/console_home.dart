// Signed-in console shell: adaptive navigation (rail on wide desktop/web,
// bottom bar on narrow mobile web) across Devices, Events, Billing, Account.
import 'package:flutter/material.dart';

import '../services/console_controller.dart';
import 'account_screen.dart';
import 'billing_screen.dart';
import 'devices_screen.dart';
import 'events_screen.dart';

class ConsoleHome extends StatefulWidget {
  const ConsoleHome({super.key, required this.controller});

  final ConsoleController controller;

  @override
  State<ConsoleHome> createState() => _ConsoleHomeState();
}

class _ConsoleHomeState extends State<ConsoleHome> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.devices_outlined, selected: Icons.devices, label: 'Devices'),
    (icon: Icons.graphic_eq_outlined, selected: Icons.graphic_eq, label: 'Events'),
    (icon: Icons.workspace_premium_outlined, selected: Icons.workspace_premium, label: 'Billing'),
    (icon: Icons.person_outline, selected: Icons.person, label: 'Account'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final body = AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => _screen(_index),
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1100,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Icon(Icons.graphic_eq, size: 28),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }

  Widget _screen(int index) {
    switch (index) {
      case 0:
        return DevicesScreen(controller: widget.controller);
      case 1:
        return EventsScreen(controller: widget.controller);
      case 2:
        return BillingScreen(controller: widget.controller);
      case 3:
        return AccountScreen(controller: widget.controller);
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Shared page chrome: a title, a refresh action, and scrollable content.
class ConsolePage extends StatelessWidget {
  const ConsolePage({
    super.key,
    required this.title,
    required this.child,
    this.onRefresh,
    this.actions = const [],
  });

  final String title;
  final Widget child;
  final Future<void> Function()? onRefresh;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.headlineSmall),
                ),
                ...actions,
                if (onRefresh != null)
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
          ),
          Expanded(
            child: onRefresh == null
                ? _content(context)
                : RefreshIndicator(
                    onRefresh: onRefresh!,
                    child: _content(context),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [child],
    );
  }
}
