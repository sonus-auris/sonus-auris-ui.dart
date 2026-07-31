// Speaks short spoken cues (TTS) confirming capture state for eyes-free use.
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/services.dart';

/// Speaks short verbal cues ("recording", "stopped", "saved") so the user can
/// confirm capture state without looking at the screen. All speech is gated by
/// [enabled] and failures are swallowed — feedback must never break recording.
class RecordingFeedback {
  RecordingFeedback({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool enabled = false;
  bool _configured = false;

  Future<void> _ensureConfigured() async {
    if (_configured) {
      return;
    }
    _configured = true;
    try {
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(false);
    } catch (_) {
      // Best effort: some platforms reject configuration before first use.
    }
  }

  /// Speaks [phrase]. Ambient cues are gated by [enabled]; pass [force] for a
  /// direct confirmation of a deliberate user action (quality switch, restart)
  /// so it is heard even when ambient verbal cues are turned off.
  Future<void> say(String phrase, {bool force = false}) async {
    if (!enabled && !force) {
      return;
    }
    try {
      await _ensureConfigured();
      await _tts.stop();
      await _tts.speak(phrase);
    } catch (_) {
      // Never propagate TTS failures into the capture pipeline.
    }
  }

<<<<<<< HEAD
  /// A short non-verbal acknowledgement used for safety-word and collision
  /// cues. Unlike spoken status, this remains recognizable in noisy settings.
  Future<void> ding() async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      // Best effort on platforms without a system alert sound.
=======
  /// Plays a short alert tone — the "ding" that marks a heard keyword or safe
  /// word. Unlike ambient cues this always sounds (a caught phrase is worth
  /// hearing even with verbal cues off) and, like [say], never throws into the
  /// capture pipeline.
  Future<void> chime() async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      // Some platforms have no alert sound; a missing ding must never surface.
>>>>>>> origin/main
    }
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
