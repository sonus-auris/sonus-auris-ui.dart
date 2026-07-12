# lib

The Flutter/Dart source for the Sonus Auris app — a privacy-first continuous
audio "dashcam": it keeps a rolling, encrypted local buffer of audio, optionally
streams it to the user's own cloud storage, runs on-device acoustic analysis
(FFT snore/music/speech detection and sleep sensing), and does all of it under
Supabase auth on a user-controlled schedule.

- **[main.dart](main.dart)** — mobile entrypoint. Boots Flutter, constructs the
  `AppController`, wires foreground-service / alarm plugins, and runs the UI.
- **[main_desktop.dart](main_desktop.dart)** — desktop entrypoint (the desktop
  sibling of the mobile build; shares the same `src/` logic).
- **[src/](src/)** — all app logic: state orchestration, models, services, and
  theming. See [src/README.md](src/README.md).
