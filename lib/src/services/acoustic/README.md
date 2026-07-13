# lib/src/services/acoustic

The on-device acoustic analysis engine. Everything here runs locally on the
phone (audio is encrypted before it ever leaves the device), so all recognition
happens inside the local plaintext window. The detectors are intentionally
lightweight FFT heuristics — non-diagnostic and tunable — not ML models.

Pipeline: decimated mono audio → per-frame FFT features → each detector →
`AcousticDetection` events. `AcousticAnalyzer` (one level up) drives this on a
background isolate so capture never blocks.

- **[spectral_features.dart](spectral_features.dart)** — `SpectralAnalyzer` /
  `SpectralFrame`: the shared FFT front-end producing per-frame features
  (centroid, flatness, band ratios, RMS/dB) every detector consumes.
- **[acoustic_pipeline.dart](acoustic_pipeline.dart)** — fans frames out to the
  enabled detectors (`AcousticDetectorFlags`) and collects their detections.
- **[snore_detector.dart](snore_detector.dart)** — low, tonal, rhythmic bursts →
  snore episodes; watches for apnea-like gaps.
- **[music_detector.dart](music_detector.dart)** — loud, pitched, beat-carrying
  audio → music.
- **[speech_detector.dart](speech_detector.dart)** — loud, voiced-band,
  syllable-modulated audio → speech.
- **[sleep_cycle_detector.dart](sleep_cycle_detector.dart)** — heuristic,
  non-diagnostic estimate of personal sleep-cycle length (with optional cycle
  alarms) from FFT/snore/quiet/arousal cues.
