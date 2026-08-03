import 'pagelet_model.dart';

/// Fail-closed policy checks that are stricter than the portable JSON shape.
///
/// The schema defines the globally compiled-in action vocabulary. This policy
/// restricts which of those actions may appear on each reviewed surface.
abstract final class PageletPolicy {
  static String? violation(PageletDocument document) {
    String? violation;

    void visit(List<PageletComponent> components) {
      for (final component in components) {
        if (violation != null) return;
        final action = component.action;
        if (action != null) {
          if (!_allowedActions(document.surface).contains(action.kind)) {
            violation =
                '${action.kind.wireName} is not allowed on ${document.surface.wireName}';
            return;
          }
          if (_requiresConfirmation(action.kind) &&
              !action.requiresConfirmation) {
            violation = '${action.kind.wireName} requires native confirmation';
            return;
          }
        }
        visit(component.children);
      }
    }

    visit(document.components);
    return violation;
  }

  static Set<PageletActionKind> _allowedActions(PageletSurface surface) {
    return switch (surface) {
      PageletSurface.deviceSummary ||
      PageletSurface.accountSummary ||
      PageletSurface.connectionStatus => const {
          PageletActionKind.navigate,
          PageletActionKind.refresh,
        },
      PageletSurface.help ||
      PageletSurface.privacy ||
      PageletSurface.releaseNotes => const {
          PageletActionKind.openAllowlistedUrl,
        },
      PageletSurface.diagnostics => const {
          PageletActionKind.refresh,
        },
      PageletSurface.acousticEventSummary => const {
          PageletActionKind.navigate,
          PageletActionKind.playAuthorizedItem,
        },
    };
  }

  static bool _requiresConfirmation(PageletActionKind kind) {
    return switch (kind) {
      PageletActionKind.confirmDeviceRename ||
      PageletActionKind.confirmDeviceRevoke => true,
      _ => false,
    };
  }
}
