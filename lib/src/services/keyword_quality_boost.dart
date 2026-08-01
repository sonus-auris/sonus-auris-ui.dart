/// Tracks a sustained "record at full quality" window opened when the user
/// speaks a configured keyword or safe word.
///
/// Adaptive quality normally downsamples quiet audio to save space. After a
/// keyword is heard we want the *following* stretch kept at full fidelity even
/// while it is quiet, so a caught phrase isn't followed by low-quality audio.
/// Each trigger (re)extends the window; overlapping triggers never shorten it.
///
/// Pure and clock-injected so the window logic is unit-testable without a
/// recorder or a real clock.
class KeywordQualityBoost {
  DateTime? _until;

  /// The instant the boost currently lasts until, or null if never triggered.
  DateTime? get activeUntil => _until;

  /// Open (or extend) the window to `now + window`. A later expiry always wins;
  /// a trigger that would end sooner than the current window is ignored, so a
  /// quiet keyword during an existing boost can only lengthen it.
  void trigger(DateTime now, Duration window) {
    final candidate = now.add(window);
    if (_until == null || candidate.isAfter(_until!)) {
      _until = candidate;
    }
  }

  /// Whether full quality should currently be forced. False once the window has
  /// elapsed (or if it was never opened).
  bool isActive(DateTime now) {
    final until = _until;
    return until != null && now.isBefore(until);
  }

  /// Forget any open window (e.g. when recording stops).
  void clear() {
    _until = null;
  }
}
