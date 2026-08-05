## Summary

Describe the user-visible behavior and the platforms affected.

## Validation

- [ ] `flutter analyze` passes.
- [ ] Relevant unit, widget, browser, desktop, iOS, and Android tests pass.
- [ ] No secrets, raw audio, reusable bearer credentials, or user-sensitive fixture data were committed.

## Rust / Flutter desktop parity

- [ ] I reviewed the matching feature ID in `docs/desktop-feature-manifest.json`.
- [ ] The paired Rust desktop implementation is included, already equivalent, platform-specific with justification, or linked to a time-bounded Linear deferral.
- [ ] User-visible desktop behavior, accessibility, error states, offline behavior, and Quit semantics remain aligned.

## Pagelet / remote-content changes

Complete this section when pagelet models, renderers, actions, remote content, or related policies change.

- [ ] The canonical schema, action manifest, surface inventory, and fixtures in `sonus-auris-interfaces` were updated first or are unchanged.
- [ ] The `pagelet conformance report` workflow passes and its `flutter-pagelet-conformance` artifact was reviewed.
- [ ] The report contains no unexpected `inventory-only` scenario.
- [ ] Unknown versions, fields, components, actions, wrong-surface actions, oversized payloads, replay, stale/future envelopes, malformed input, and offline fallback remain covered.
- [ ] Any mutation has a compiled authorization requirement, exact parameter policy, payload ceiling, timeout, and native confirmation gate.
- [ ] No mobile JavaScript/native bridge, downloaded executable functionality, generic native API, arbitrary HTTP/database/filesystem capability, or dynamic permission prompt was added.
- [ ] Recording, permissions, consent, retention, authentication/MFA, purchases, account deletion, background capture, playback authorization, and shutdown remain native and offline-capable.
- [ ] DEN-1401 reviewer notes, screenshots/video, privacy/data-safety disclosures, and store metadata were updated when a reviewed remote surface changed.

## Tracking

Linear issue(s):
Paired Rust PR or deferral:
