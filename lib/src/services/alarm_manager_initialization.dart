// Single-flight, bounded initialization for the Android alarm-manager plugin.
import 'dart:async';

typedef AlarmManagerInitializer = Future<bool> Function();

/// Prevents schedule operations from reaching the alarm-manager plugin before
/// its native service is ready, without allowing a slow platform channel to
/// block app startup indefinitely.
///
/// Concurrent callers share one native attempt. A caller only waits
/// [waitTimeout], but timing out does not cancel or duplicate the native call:
/// a late successful completion is cached and used by the next schedule sync.
/// Attempts that explicitly fail or throw are cleared so a later sync can
/// retry, making transient boot-time plugin failures recoverable.
class AlarmManagerInitializationGate {
  AlarmManagerInitializationGate({
    required this.initializer,
    this.waitTimeout = const Duration(seconds: 3),
  }) : assert(waitTimeout > Duration.zero);

  final AlarmManagerInitializer initializer;
  final Duration waitTimeout;

  Future<bool>? _inFlight;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// The current native attempt, or an already-successful result. This lets a
  /// schedule platform recover a deferred operation if initialization finishes
  /// after that operation's bounded wait expired.
  Future<bool>? get currentAttemptOrReady {
    if (_initialized) {
      return Future<bool>.value(true);
    }
    return _inFlight;
  }

  Future<bool> ensureInitialized() async {
    if (_initialized) {
      return true;
    }
    final attempt = _inFlight ??= _runAttempt();
    return attempt.timeout(waitTimeout, onTimeout: () => false);
  }

  Future<bool> _runAttempt() async {
    try {
      final initialized = await initializer();
      if (initialized) {
        _initialized = true;
      }
      return initialized;
    } catch (_) {
      return false;
    } finally {
      _inFlight = null;
    }
  }
}
