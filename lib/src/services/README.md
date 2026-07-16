# lib/src/services

The engine room. Each service owns one concern and is constructed/owned by the
`AppController`. Services that touch platform plugins keep their pure decision
logic factored out (e.g. `transfer_gate_evaluator`, `recording_scheduler`) so it
stays unit-testable without a device.

### Capture & storage
- **[segment_recorder.dart](segment_recorder.dart)** — core rolling-buffer
  recorder: mic → overlapping WAV segments, feeds the acoustic pipeline, emits
  recorder state and trigger events.
- **[wav_segment_writer.dart](wav_segment_writer.dart)** — streaming WAV writer.
- **[segment_index.dart](segment_index.dart)** — on-disk catalog of segments.
- **[capture_resume_coordinator.dart](capture_resume_coordinator.dart)** — pure
  policy that restarts an interrupted/stalled capture so long unattended
  recordings survive.
- **[background_capture_service.dart](background_capture_service.dart)** — Android
  foreground-service notification that keeps capture alive.
- **[audio_encoder.dart](audio_encoder.dart)** — WAV → AAC/M4A bridge (on-device).

### Cloud upload & gating
- **[s3_storage_client.dart](s3_storage_client.dart)** — direct SigV4 upload to
  the user's own S3 bucket.
- **[sound_recorder_backend_client.dart](sound_recorder_backend_client.dart)** —
  backend-mediated upload for non-S3 providers.
- **[icloud_sync_service.dart](icloud_sync_service.dart)** — mirror segments into
  the user's iCloud Drive.
- **[power_network_gate.dart](power_network_gate.dart)** / **[transfer_gate_evaluator.dart](transfer_gate_evaluator.dart)** — gate uploads on
  battery/network (capture is never gated).

### On-device analysis & sensing
- **[acoustic/](acoustic/)** — the FFT detector pipeline (snore/music/speech/
  sleep). See [acoustic/README.md](acoustic/README.md).
- **[acoustic_analyzer.dart](acoustic_analyzer.dart)** — runs that pipeline on a
  background isolate.
- **[spectral_sidecar.dart](spectral_sidecar.dart)** — writes a time-aligned FFT
  features sidecar next to each segment.
- **[sleep_sensor_service.dart](sleep_sensor_service.dart)** / **[sleep_signal_model.dart](sleep_signal_model.dart)** — native motion/light/context
  sensing that augments audio for sleep detection.
- **[activity_summarizer.dart](activity_summarizer.dart)** — turns a day's
  signals into human-readable activity notes.

### Scheduling & triggers
- **[recording_scheduler.dart](recording_scheduler.dart)** / **[recording_schedule_platform.dart](recording_schedule_platform.dart)** — arm/disarm capture at
  schedule-window boundaries via OS alarms/notifications.
- **[context_trigger_service.dart](context_trigger_service.dart)** / **[context_trigger_sources.dart](context_trigger_sources.dart)** — wake on connectivity/
  Wi-Fi/Bluetooth events.
- **[local_notifications_service.dart](local_notifications_service.dart)** — the
  single owner of local notifications.

### Auth, identity & secrets
- **[supabase_auth_client.dart](supabase_auth_client.dart)** / **[supabase_rest_client.dart](supabase_rest_client.dart)** — Supabase GoTrue auth +
  RLS-scoped PostgREST writes.
- **[settings_store.dart](settings_store.dart)** — persists config/secrets/
  consent/sleep profiles.
- **[crypto/](crypto/)** — the zero-knowledge segment encryption. See
  [crypto/README.md](crypto/README.md).

### Recognition & LLMs
- **[recognition/](recognition/)** — routes FFT-gate detections to the heavy
  recognizers: `recognition_orchestrator.dart` (music → ShazamKit, tonal
  non-music → bird ID), `bird_classifier.dart` (Google Perch v2 via TFLite,
  fully on-device), and `model_manager.dart` (models are downloaded on demand
  and checksum-verified — never bundled, so the store binary stays small).
- **[llm/](llm/)** — provider-agnostic chat-completion clients over plain
  HTTP: `anthropic_llm_client.dart` (Claude Fable 5 / Opus 4.8, with
  server-side refusal fallbacks on Fable), `openai_llm_client.dart`, and
  `gemini_llm_client.dart`, behind the shared `LlmClient` interface.

### Playback, voice & extras
- **[playback_service.dart](playback_service.dart)** — local segment playback.
- **[voice/](voice/)** — hands-free voice commands. See [voice/README.md](voice/README.md).
- **[recording_feedback.dart](recording_feedback.dart)** — spoken (TTS) capture cues.
- **[speech_to_text_client.dart](speech_to_text_client.dart)** / **[on_device_speech_client.dart](on_device_speech_client.dart)** — cloud vs. on-device STT.
- **[shazam_client.dart](shazam_client.dart)** / **[memory_publisher.dart](memory_publisher.dart)** / **[spotify_client.dart](spotify_client.dart)** / **[soundcloud_client.dart](soundcloud_client.dart)** / **[music_oauth_service.dart](music_oauth_service.dart)** / **[oauth_browser.dart](oauth_browser.dart)** — music recognition + "Day of My Life" publishing.
- **[day_of_life_archiver.dart](day_of_life_archiver.dart)** — assembles and
  publishes a day's audio as a private track.
- **[location_service.dart](location_service.dart)** / **[place_resolver.dart](place_resolver.dart)** — opt-in GPS tagging and reverse geocoding.
- **[diagnostic_log.dart](diagnostic_log.dart)** — in-memory diagnostics feed.
