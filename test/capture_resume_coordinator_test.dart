import 'package:audio_dashcam/src/services/capture_resume_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fixed base time; tests advance it explicitly so the policy is exercised
  // without any real clock or timers.
  final t0 = DateTime.utc(2026, 1, 1, 22, 0, 0);
  DateTime at(Duration d) => t0.add(d);

  late CaptureResumeCoordinator coordinator;
  late List<String> resumes;

  CaptureResumeCoordinator make({bool enabled = true}) {
    final c = CaptureResumeCoordinator(
      enabled: enabled,
      stallThreshold: const Duration(seconds: 6),
      postInterruptionGrace: const Duration(milliseconds: 1500),
    );
    resumes = [];
    c.resumeRequests.listen(resumes.add);
    return c;
  }

  tearDown(() async {
    await coordinator.dispose();
  });

  test('emits nothing while capture stays alive', () async {
    coordinator = make();
    coordinator.start(t0);
    for (var s = 1; s <= 20; s++) {
      coordinator.notifyChunk(at(Duration(seconds: s)));
      coordinator.tick(at(Duration(seconds: s)));
    }
    await Future<void>.delayed(Duration.zero);
    expect(resumes, isEmpty);
  });

  test('requests resume when an interruption never resumes', () async {
    coordinator = make();
    coordinator.start(t0);
    coordinator.notifyChunk(at(const Duration(seconds: 1)));

    // A 30s phone call: begin, no chunks during it, then end.
    coordinator.onInterruptionBegin();
    // The stall watchdog must stand down while the call owns the audio session.
    coordinator.tick(at(const Duration(seconds: 20)));
    expect(resumes, isEmpty);

    coordinator.onInterruptionEnd(at(const Duration(seconds: 31)));
    // Within the grace window the plugin might still resume: hold off.
    coordinator.tick(at(const Duration(seconds: 31, milliseconds: 500)));
    expect(resumes, isEmpty);

    // Grace elapsed with no fresh audio -> force a restart.
    coordinator.tick(at(const Duration(seconds: 33)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, ['interruption did not resume']);
  });

  test('stays seamless when the plugin resumes within the grace window',
      () async {
    coordinator = make();
    coordinator.start(t0);
    coordinator.onInterruptionBegin();
    coordinator.onInterruptionEnd(at(const Duration(seconds: 10)));
    // Plugin resumed: a chunk arrives before the grace deadline.
    coordinator.notifyChunk(at(const Duration(seconds: 10, milliseconds: 800)));
    coordinator.tick(at(const Duration(seconds: 12)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, isEmpty);
  });

  test('requests resume when capture silently stalls (no interruption)',
      () async {
    coordinator = make();
    coordinator.start(t0);
    coordinator.notifyChunk(at(const Duration(seconds: 1)));
    // No chunks for longer than the stall threshold.
    coordinator.tick(at(const Duration(seconds: 5)));
    expect(resumes, isEmpty);
    coordinator.tick(at(const Duration(seconds: 8)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, ['capture stalled']);
  });

  test('requests resume immediately on a capture stream error', () async {
    coordinator = make();
    coordinator.start(t0);
    coordinator.onCaptureError(at(const Duration(seconds: 2)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, ['capture stream error']);
  });

  test('does not re-emit until capture proves alive again (dedup)', () async {
    coordinator = make();
    coordinator.start(t0);
    coordinator.notifyChunk(at(const Duration(seconds: 1)));
    coordinator.tick(at(const Duration(seconds: 8))); // stalls -> one emit
    coordinator.tick(at(const Duration(seconds: 9)));
    coordinator.tick(at(const Duration(seconds: 10)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, ['capture stalled']);

    // A fresh chunk clears the pending flag; a later stall can fire again.
    coordinator.notifyChunk(at(const Duration(seconds: 11)));
    coordinator.tick(at(const Duration(seconds: 18)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, ['capture stalled', 'capture stalled']);
  });

  test('disabled gate is a complete no-op', () async {
    coordinator = make(enabled: false);
    coordinator.start(t0);
    coordinator.onInterruptionBegin();
    coordinator.onInterruptionEnd(at(const Duration(seconds: 1)));
    coordinator.onCaptureError(at(const Duration(seconds: 2)));
    coordinator.tick(at(const Duration(seconds: 30)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, isEmpty);
  });

  test('stop() suppresses any pending resume', () async {
    coordinator = make();
    coordinator.start(t0);
    coordinator.notifyChunk(at(const Duration(seconds: 1)));
    coordinator.stop();
    // After a deliberate stop nothing should be requested.
    coordinator.onInterruptionEnd(at(const Duration(seconds: 2)));
    coordinator.tick(at(const Duration(seconds: 30)));
    coordinator.onCaptureError(at(const Duration(seconds: 31)));
    await Future<void>.delayed(Duration.zero);
    expect(resumes, isEmpty);
  });
}
