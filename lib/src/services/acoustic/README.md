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
  (centroid, flatness, spectral and time-domain crest, band ratios, RMS/dB,
  peak amplitude, and clipping rate) every detector consumes.
- **[acoustic_pipeline.dart](acoustic_pipeline.dart)** — fans frames out to the
  enabled detectors (`AcousticDetectorFlags`) and collects their detections.
- **[snore_detector.dart](snore_detector.dart)** — low, tonal, rhythmic bursts →
  snore episodes; watches for apnea-like gaps.
- **[music_detector.dart](music_detector.dart)** — loud, pitched, beat-carrying
  audio → music.
- **[speech_detector.dart](speech_detector.dart)** — loud, voiced-band,
  syllable-modulated audio → speech.
- **[safety_sound_detector.dart](safety_sound_detector.dart)** — sudden level
  rise plus transient/broadband evidence → sudden loud noise; sustained loud
  speech-band energy → raised voice; three separated raised-voice bursts → a
  possible argument *pattern*. These labels never assert an accident, speaker
  count, identity, or that an argument actually occurred.
- **[sleep_cycle_detector.dart](sleep_cycle_detector.dart)** — heuristic,
  non-diagnostic estimate of personal sleep-cycle length (with optional cycle
  alarms) from FFT/snore/quiet/arousal cues.

Finalized WAV segments are also analyzed off the realtime path by
`../spectral_sidecar.dart`. Its versioned feature track and compact detection
summary are written before upload draining begins. Direct S3 uploads put the
sidecar next to the audio and encrypt it independently; backend uploads attach
the compact summary to the segment metadata.
