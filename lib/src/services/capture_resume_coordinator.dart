// Pure, clock-injected policy deciding when an interrupted or stalled capture stream should restart so long unattended recordings survive.
import 'package:rxdart/rxdart.dart';

/// Decides when an interrupted or stalled capture stream should be restarted so
/// a long unattended recording (e.g. all night) survives phone calls, alarms,
/// Siri, or a transient media-services reset.
///
/// On iOS the `audio` background mode keeps the microphone open with the screen
/// locked, but it does NOT guarantee the stream comes back on its own after an
/// interruption: iOS frequently ends an interruption without the "should
/// resume" hint, leaving the recorder paused for the rest of the night with no
/// error. Unlike a music player (which must respect that hint and stay silent),
/// a recorder wants to resume unconditionally the moment the audio hardware is
/// free again. This coordinator encodes that policy.
///
/// It is deliberately pure: it owns no timers and reads no clock of its own. The
/// [SegmentRecorder] feeds it lifecycle calls, capture-liveness pings, OS
/// interruption edges, and periodic [tick]s — all with an explicit `now` — and
/// listens to [resumeRequests] for the moments a restart is warranted. Keeping
/// it clock-injected makes the resume policy unit-testable without real audio
/// hardware. When [enabled] is false every method is a no-op and nothing is ever
/// emitted, so the surrounding capture path behaves exactly as before.
class CaptureResumeCoordinator {
  CaptureResumeCoordinator({
    this.enabled = true,
    this.stallThreshold = const Duration(seconds: 6),
    this.postInterruptionGrace = const Duration(milliseconds: 1500),
  });

  /// Master gate. When false the coordinator never emits (feature off).
  final bool enabled;

  /// How long capture may deliver no audio before it is treated as stalled.
  final Duration stallThreshold;

  /// Grace given to the recorder plugin to resume its own stream after an OS
  /// interruption ends, before we force a restart. Keeps short interruptions
  /// (a Siri ding) seamless while still recovering from ones that never resume.
  final Duration postInterruptionGrace;

  final PublishSubject<String> _resumeRequests = PublishSubject<String>();

  bool _recording = false;
  bool _resumePending = false;
  bool _interruptionActive = false;
  DateTime? _lastChunkAt;
  DateTime? _resumeDeadline;

  /// Reasons a capture restart is warranted, each a short human-readable string
  /// suitable for the diagnostic log.
  Stream<String> get resumeRequests => _resumeRequests.stream;

  /// True while an OS interruption (call, alarm, Siri…) is in progress.
  bool get isInterrupted => _interruptionActive;

  /// Capture has (re)started and is expected to deliver audio from [now] on.
  void start(DateTime now) {
    _recording = true;
    _resumePending = false;
    _interruptionActive = false;
    _lastChunkAt = now;
    _resumeDeadline = null;
  }

  /// Capture has been deliberately stopped; no resume should be requested.
  void stop() {
    _recording = false;
    _resumePending = false;
    _interruptionActive = false;
    _lastChunkAt = null;
    _resumeDeadline = null;
  }

  /// A capture chunk arrived: capture is demonstrably alive again.
  void notifyChunk(DateTime now) {
    if (!enabled || !_recording) {
      return;
    }
    _lastChunkAt = now;
    _resumePending = false;
    _resumeDeadline = null;
  }

  /// The OS signalled that an interruption is beginning. Capture is paused while
  /// it lasts, so the stall watchdog stands down until it ends.
  void onInterruptionBegin() {
    if (!enabled || !_recording) {
      return;
    }
    _interruptionActive = true;
  }

  /// The OS signalled that the interruption ended. The recorder plugin may
  /// resume its own stream; we give it [postInterruptionGrace] before forcing a
  /// restart so short interruptions stay seamless.
  void onInterruptionEnd(DateTime now) {
    _interruptionActive = false;
    if (!enabled || !_recording || _resumePending) {
      return;
    }
    _resumeDeadline = now.add(postInterruptionGrace);
  }

  /// The capture stream errored out (e.g. media services were reset). Restart
  /// right away; there is nothing to wait for.
  void onCaptureError(DateTime now) {
    if (!enabled || !_recording || _resumePending) {
      return;
    }
    _emit('capture stream error');
  }

  /// Periodic watchdog. Emits a resume request when an interruption failed to
  /// resume within the grace window, or when capture has gone silent for longer
  /// than [stallThreshold]. Stands down while an interruption is still active —
  /// the audio session belongs to the call/alarm and a restart would only fail.
  void tick(DateTime now) {
    if (!enabled || !_recording || _resumePending || _interruptionActive) {
      return;
    }
    final deadline = _resumeDeadline;
    if (deadline != null) {
      if (now.isBefore(deadline)) {
        // Still inside the grace window: let the plugin resume on its own.
        // The pre-interruption [_lastChunkAt] is expectedly stale here, so we
        // must not let the generic stall check below fire on it yet.
        return;
      }
      _resumeDeadline = null;
      final lastChunk = _lastChunkAt;
      final resumed =
          lastChunk != null &&
          now.difference(lastChunk) < postInterruptionGrace;
      if (!resumed) {
        _emit('interruption did not resume');
        return;
      }
      // Plugin resumed within grace; fall through to the normal stall watch.
    }
    final lastChunk = _lastChunkAt;
    if (lastChunk != null && now.difference(lastChunk) >= stallThreshold) {
      _emit('capture stalled');
    }
  }

  void _emit(String reason) {
    _resumePending = true;
    _resumeDeadline = null;
    _resumeRequests.add(reason);
  }

  Future<void> dispose() async {
    await _resumeRequests.close();
  }
}
