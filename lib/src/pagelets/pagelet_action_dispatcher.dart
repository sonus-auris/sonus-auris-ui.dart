import 'dart:convert';

import 'pagelet_model.dart';
import 'pagelet_protocol.dart';

enum PageletAuthorizationState {
  publicContent,
  signedIn,
  aal2,
  authorizedItem,
}

enum PageletActionClassification { read, mutation }

enum PageletActionOutcome { completed, cancelled }

typedef PageletConfirmation = Future<bool> Function(PageletAction action);
typedef PageletActionExecutor = Future<void> Function(PageletAction action);

class PageletActionDispatcher {
  const PageletActionDispatcher({
    required this.platform,
    required this.authorization,
    required this.confirm,
    required this.executeRead,
    required this.executeMutation,
  });

  final PageletHostPlatform platform;
  final PageletAuthorizationState authorization;
  final PageletConfirmation confirm;
  final PageletActionExecutor executeRead;
  final PageletActionExecutor executeMutation;

  Future<PageletActionOutcome> dispatch(PageletAction action) async {
    final policy = _policies[action.kind];
    if (policy == null) {
      throw StateError('Pagelet action is not compiled into this host');
    }
    if (!policy.platforms.contains(platform)) {
      throw StateError('Pagelet action is not supported on ${platform.name}');
    }
    if (action.requiresConfirmation != policy.requiresConfirmation) {
      throw StateError('Pagelet action confirmation contract mismatch');
    }
    if (!_authorizationAllows(policy.requiredAuthorization)) {
      throw StateError('Pagelet action authorization requirement not met');
    }
    _validateParams(action, policy);
    final payloadBytes = utf8.encode(jsonEncode(action.params)).length;
    if (payloadBytes > policy.maxPayloadBytes) {
      throw StateError('Pagelet action payload exceeds compiled limit');
    }

    if (policy.classification == PageletActionClassification.mutation) {
      final approved = await confirm(action).timeout(policy.timeout);
      if (!approved) return PageletActionOutcome.cancelled;
      await executeMutation(action).timeout(policy.timeout);
      return PageletActionOutcome.completed;
    }

    await executeRead(action).timeout(policy.timeout);
    return PageletActionOutcome.completed;
  }

  bool _authorizationAllows(PageletAuthorizationState required) {
    return switch (required) {
      PageletAuthorizationState.publicContent => true,
      PageletAuthorizationState.signedIn =>
        authorization == PageletAuthorizationState.signedIn ||
            authorization == PageletAuthorizationState.aal2 ||
            authorization == PageletAuthorizationState.authorizedItem,
      PageletAuthorizationState.aal2 =>
        authorization == PageletAuthorizationState.aal2,
      PageletAuthorizationState.authorizedItem =>
        authorization == PageletAuthorizationState.authorizedItem,
    };
  }
}

class _ActionPolicy {
  const _ActionPolicy({
    required this.classification,
    required this.requiredAuthorization,
    required this.requiresConfirmation,
    required this.timeout,
    required this.maxPayloadBytes,
    required this.requiredParams,
    required this.platforms,
  });

  final PageletActionClassification classification;
  final PageletAuthorizationState requiredAuthorization;
  final bool requiresConfirmation;
  final Duration timeout;
  final int maxPayloadBytes;
  final Set<String> requiredParams;
  final Set<PageletHostPlatform> platforms;
}

const _nativePlatforms = <PageletHostPlatform>{
  PageletHostPlatform.ios,
  PageletHostPlatform.android,
  PageletHostPlatform.macos,
  PageletHostPlatform.windows,
  PageletHostPlatform.linux,
};

const _policies = <PageletActionKind, _ActionPolicy>{
  PageletActionKind.navigate: _ActionPolicy(
    classification: PageletActionClassification.read,
    requiredAuthorization: PageletAuthorizationState.signedIn,
    requiresConfirmation: false,
    timeout: Duration(seconds: 5),
    maxPayloadBytes: 1024,
    requiredParams: {'route'},
    platforms: _nativePlatforms,
  ),
  PageletActionKind.refresh: _ActionPolicy(
    classification: PageletActionClassification.read,
    requiredAuthorization: PageletAuthorizationState.signedIn,
    requiresConfirmation: false,
    timeout: Duration(seconds: 10),
    maxPayloadBytes: 512,
    requiredParams: {},
    platforms: _nativePlatforms,
  ),
  PageletActionKind.confirmDeviceRename: _ActionPolicy(
    classification: PageletActionClassification.mutation,
    requiredAuthorization: PageletAuthorizationState.aal2,
    requiresConfirmation: true,
    timeout: Duration(seconds: 15),
    maxPayloadBytes: 1024,
    requiredParams: {'deviceId', 'proposedName'},
    platforms: _nativePlatforms,
  ),
  PageletActionKind.confirmDeviceRevoke: _ActionPolicy(
    classification: PageletActionClassification.mutation,
    requiredAuthorization: PageletAuthorizationState.aal2,
    requiresConfirmation: true,
    timeout: Duration(seconds: 15),
    maxPayloadBytes: 512,
    requiredParams: {'deviceId'},
    platforms: _nativePlatforms,
  ),
  PageletActionKind.playAuthorizedItem: _ActionPolicy(
    classification: PageletActionClassification.read,
    requiredAuthorization: PageletAuthorizationState.authorizedItem,
    requiresConfirmation: false,
    timeout: Duration(seconds: 10),
    maxPayloadBytes: 512,
    requiredParams: {'itemId'},
    platforms: _nativePlatforms,
  ),
  PageletActionKind.openAllowlistedUrl: _ActionPolicy(
    classification: PageletActionClassification.read,
    requiredAuthorization: PageletAuthorizationState.publicContent,
    requiresConfirmation: false,
    timeout: Duration(seconds: 5),
    maxPayloadBytes: 1024,
    requiredParams: {'urlId'},
    platforms: _nativePlatforms,
  ),
};

void _validateParams(PageletAction action, _ActionPolicy policy) {
  final keys = action.params.keys.toSet();
  if (!keys.containsAll(policy.requiredParams) ||
      !policy.requiredParams.containsAll(keys)) {
    throw StateError('Pagelet action parameters do not match compiled policy');
  }

  String requiredString(String name, {required int maxLength}) {
    final value = action.params[name];
    if (value is! String || value.isEmpty || value.length > maxLength) {
      throw StateError('Invalid pagelet action parameter: $name');
    }
    return value;
  }

  switch (action.kind) {
    case PageletActionKind.navigate:
      requiredString('route', maxLength: 80);
    case PageletActionKind.refresh:
      break;
    case PageletActionKind.confirmDeviceRename:
      requiredString('deviceId', maxLength: 128);
      requiredString('proposedName', maxLength: 80);
    case PageletActionKind.confirmDeviceRevoke:
      requiredString('deviceId', maxLength: 128);
    case PageletActionKind.playAuthorizedItem:
      requiredString('itemId', maxLength: 128);
    case PageletActionKind.openAllowlistedUrl:
      requiredString('urlId', maxLength: 80);
  }
}
