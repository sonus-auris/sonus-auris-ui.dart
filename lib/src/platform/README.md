# lib/src/platform

Tiny platform / form-factor helpers. Kept dependency-light so they can be
imported from either UI or logic without pulling in heavy plugins. The
`AppController` and services are otherwise shared unchanged across mobile and
desktop.

- **[form_factor.dart](form_factor.dart)** — `FormFactor` (drives presentation)
  and `DeviceRole` (recorder vs. master-viewer, drives logic) enums, plus static
  platform predicates.
- **[desktop_autostart.dart](desktop_autostart.dart)** — registers the desktop
  build as a login item (the desktop sibling of mobile boot-start); no-op on
  mobile.
