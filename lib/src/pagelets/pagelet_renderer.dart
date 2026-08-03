import 'package:flutter/material.dart';

import 'pagelet_model.dart';

/// Renders a validated pagelet using widgets compiled into the app binary.
///
/// This renderer does not evaluate scripts, load remote widgets, request
/// permissions, or expose a JavaScript/native bridge.
class PageletRenderer extends StatelessWidget {
  const PageletRenderer({
    required this.document,
    required this.onAction,
    super.key,
  });

  final PageletDocument document;
  final ValueChanged<PageletAction>? onAction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: document.title ?? document.pageletId,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (document.title case final title?) ...[
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
              ],
              for (final component in document.components)
                _PageletComponentView(
                  component: component,
                  onAction: onAction,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bounded loading/error/fallback host for pagelet surfaces.
class PageletSurfaceView extends StatelessWidget {
  const PageletSurfaceView({
    required this.document,
    required this.onAction,
    required this.fallback,
    this.isLoading = false,
    this.error,
    super.key,
  });

  final PageletDocument? document;
  final ValueChanged<PageletAction>? onAction;
  final Widget fallback;
  final bool isLoading;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Semantics(
        liveRegion: true,
        label: 'Loading shared content',
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final current = document;
    if (error != null || current == null) {
      return Semantics(
        container: true,
        label: 'Shared content unavailable; showing bundled fallback',
        child: fallback,
      );
    }
    return PageletRenderer(document: current, onAction: onAction);
  }
}

class _PageletComponentView extends StatelessWidget {
  const _PageletComponentView({
    required this.component,
    required this.onAction,
  });

  final PageletComponent component;
  final ValueChanged<PageletAction>? onAction;

  @override
  Widget build(BuildContext context) {
    return switch (component.type) {
      PageletComponentType.section => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final child in component.children)
                _PageletComponentView(
                  component: child,
                  onAction: onAction,
                ),
            ],
          ),
        ),
      PageletComponentType.text => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            component.text!,
            style: _textStyle(context, component.semanticRole),
          ),
        ),
      PageletComponentType.status => _StatusComponent(component: component),
      PageletComponentType.metric => _MetricComponent(component: component),
      PageletComponentType.list => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in component.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• '),
                      Expanded(child: Text(item)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      PageletComponentType.button => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: onAction == null
                  ? null
                  : () => onAction!(component.action!),
              child: Text(component.text!),
            ),
          ),
        ),
      PageletComponentType.spacer => SizedBox(height: component.size!.toDouble()),
    };
  }

  TextStyle? _textStyle(
    BuildContext context,
    PageletSemanticRole? role,
  ) {
    final textTheme = Theme.of(context).textTheme;
    return switch (role) {
      PageletSemanticRole.heading => textTheme.titleMedium,
      PageletSemanticRole.caption => textTheme.bodySmall,
      PageletSemanticRole.status => textTheme.bodyMedium,
      PageletSemanticRole.metric => textTheme.titleSmall,
      PageletSemanticRole.action => textTheme.labelLarge,
      PageletSemanticRole.body || null => textTheme.bodyMedium,
    };
  }
}

class _StatusComponent extends StatelessWidget {
  const _StatusComponent({required this.component});

  final PageletComponent component;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, foreground, background) = switch (component.tone) {
      PageletTone.positive => (
          Icons.check_circle_outline,
          colorScheme.primary,
          colorScheme.primaryContainer,
        ),
      PageletTone.warning => (
          Icons.warning_amber_outlined,
          colorScheme.onTertiaryContainer,
          colorScheme.tertiaryContainer,
        ),
      PageletTone.critical => (
          Icons.error_outline,
          colorScheme.onErrorContainer,
          colorScheme.errorContainer,
        ),
      PageletTone.muted => (
          Icons.info_outline,
          colorScheme.onSurfaceVariant,
          colorScheme.surfaceContainerHighest,
        ),
      PageletTone.neutral || null => (
          Icons.info_outline,
          colorScheme.onSecondaryContainer,
          colorScheme.secondaryContainer,
        ),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              component.text!,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricComponent extends StatelessWidget {
  const _MetricComponent({required this.component});

  final PageletComponent component;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(component.label!)),
          const SizedBox(width: 12),
          Text(
            '${component.value ?? ''}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
    );
  }
}
