/// Coarse, *non-diagnostic* sleep stage inferred acoustically from breathing,
/// snoring, movement and quietness. These are heuristic acoustic proxies — not a
/// polysomnogram — so we only distinguish the four states that audio can plausibly
/// separate, plus [unknown] for epochs the engine can't classify.
enum SleepStage {
  /// Out of bed / moving / talking / clearly not asleep.
  awake,

  /// Light sleep (stage N1/N2 proxy): quiet but with frequent micro-movements
  /// and somewhat irregular breathing. This is where cycle-aware alarms aim to
  /// wake the sleeper.
  light,

  /// Deep sleep (slow-wave / N3 proxy): very quiet, minimal movement, slow and
  /// highly regular breathing (and steady snoring when present).
  deep,

  /// REM proxy: still body but irregular, variable breathing; snoring typically
  /// pauses. Cycles characteristically end in (or just after) REM.
  rem,

  /// Not enough signal to classify this epoch.
  unknown;

  static SleepStage fromName(String? name) {
    return SleepStage.values.firstWhere(
      (s) => s.name == name,
      orElse: () => SleepStage.unknown,
    );
  }

  /// True when the sleeper is in a shallow/easily-roused state — the moments a
  /// smart alarm prefers to fire.
  bool get isShallow => this == SleepStage.light ||
      this == SleepStage.rem ||
      this == SleepStage.awake;

  String get label {
    switch (this) {
      case SleepStage.awake:
        return 'Awake';
      case SleepStage.light:
        return 'Light sleep';
      case SleepStage.deep:
        return 'Deep sleep';
      case SleepStage.rem:
        return 'REM';
      case SleepStage.unknown:
        return 'Unknown';
    }
  }
}
