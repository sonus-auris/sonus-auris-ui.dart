// Explicit development-only escape hatch for working on local recording while
// hosted account services are unavailable. Release builds can never enable it.

import 'package:flutter/foundation.dart' show kReleaseMode;

const bool offlineDevelopmentModeRequested = bool.fromEnvironment(
  'SONUS_ENABLE_OFFLINE_MODE',
);

bool isOfflineDevelopmentModeEnabled({
  bool releaseMode = kReleaseMode,
  bool requested = offlineDevelopmentModeRequested,
}) => !releaseMode && requested;
