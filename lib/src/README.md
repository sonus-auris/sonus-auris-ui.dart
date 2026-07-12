# lib/src

All app logic lives here, split so the platform-agnostic core (`services/`,
`models/`) never depends on the UI or the form factor. Both the mobile and
desktop entrypoints share this code.

- **[app/](app/)** — the orchestration layer. `AppController` owns every service
  and drives the capture → encrypt → upload → analyse lifecycle; `AppViewModel`
  is the immutable snapshot the UI renders.
- **[models/](models/)** — plain, serializable value types (config, segments,
  detections, sessions, schedules) with no plugin dependencies.
- **[services/](services/)** — the engine room: recording, encryption, cloud
  upload, acoustic analysis, sleep sensing, scheduling, auth, and voice
  commands. See [services/README.md](services/README.md).
- **[platform/](platform/)** — thin platform/form-factor helpers (desktop
  autostart, device-role detection).
- **[theme/](theme/)** — Sonus Auris brand colours, Material theme, and logo mark.
