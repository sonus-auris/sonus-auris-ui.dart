# lib/src/models

Plain, serializable value types shared across the app. They hold no plugin
dependencies and no behaviour beyond (de)serialization and small pure helpers,
so they are trivially unit-testable and safe to pass across isolate boundaries.

Key models:

- **[app_config.dart](app_config.dart)** — user-tunable settings: retention
  windows, codec/segment params, cloud provider, schedule, detector flags,
  upload policy.
- **[cloud_provider.dart](cloud_provider.dart)** / **[cloud_connection.dart](cloud_connection.dart)** / **[cloud_secrets.dart](cloud_secrets.dart)** — the user-owned cloud
  destinations and the credentials/tokens used to reach them.
- **[recording_segment.dart](recording_segment.dart)** — one rolling audio
  segment on disk plus its upload status and metadata.
- **[recording_schedule.dart](recording_schedule.dart)** — the per-day recording
  windows the scheduler arms/disarms capture against.
- **[acoustic_detection.dart](acoustic_detection.dart)** / **[audio_trigger_event.dart](audio_trigger_event.dart)** — outputs of the on-device analysis
  (snore/music/speech events, commotion/magic-phrase triggers).
- **[sleep_cycle_profile.dart](sleep_cycle_profile.dart)** — learned per-user
  sleep-cycle observations used by the sleep-cycle detector.
- **[supabase_session.dart](supabase_session.dart)** / **[consent.dart](consent.dart)** — auth session and onboarding consents.
- **[recorder_snapshot.dart](recorder_snapshot.dart)** / **[playback_snapshot.dart](playback_snapshot.dart)** / **[storage_estimate.dart](storage_estimate.dart)** / **[transfer_gate_status.dart](transfer_gate_status.dart)** — UI-facing state snapshots.
- **[geo_tag.dart](geo_tag.dart)** / **[context_trigger.dart](context_trigger.dart)** / **[day_of_life.dart](day_of_life.dart)** / **[voice_command.dart](voice_command.dart)** / **[upload_network_policy.dart](upload_network_policy.dart)** — supporting types.
