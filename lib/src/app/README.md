# lib/src/app

The orchestration layer that sits between the UI and the services. It owns no
audio or crypto logic itself — it wires the services together and exposes a
single, renderable view of app state.

- **[app_controller.dart](app_controller.dart)** — the central orchestrator.
  Constructs and owns every service, drives the capture/encrypt/upload/analysis
  lifecycle, handles onboarding/consent and auth, and publishes state changes.
- **[app_view_model.dart](app_view_model.dart)** — the immutable snapshot the UI
  renders (config, secrets, segments, recorder/playback state, detections,
  transfer status). Rebuilt and emitted by the controller.
