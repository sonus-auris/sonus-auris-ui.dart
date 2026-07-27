# Nix development contract

The repository exposes an agent-first default shell and validation command:

```sh
nix develop
nix develop -c agent-check
nix run .#agent-check
nix flake check --show-trace
```

`agent-check` is non-interactive. It validates the flake and workflows, requires Flutter 3.44.2 to match the existing GitHub Actions toolchain, resolves packages, runs `flutter analyze --no-fatal-infos`, and runs all unit tests.

Mutable Pub, Gradle, Flutter, Dart, and XDG state is kept below `.cache/nix-agent/` unless the caller explicitly overrides those locations. Analytics are suppressed without mutating global user configuration.

## Platform boundaries

The default shell supports source work, analysis, tests, and Linux/web/desktop prerequisites that are available through Nixpkgs. Release builds remain platform-specific:

- iOS signing and App Store builds require an authorized macOS host with Xcode and signing identities;
- Android release builds require the approved Android SDK/NDK versions and signing material;
- signing keys, store credentials, device state, microphones, and cloud credentials must never be embedded in the flake or shell hook.

Add specialized named shells later if Android SDK or physical-device integration work needs a larger licensed toolchain. Keep the default shell fast enough for ordinary coding agents.

## Docker and OCI policy

The iOS and Android applications are not OCI runtime workloads. Nix is used here for development, analysis, tests, and reproducible web/desktop build tooling—not to put a mobile application into a container.

If `flutter build web` artifacts are later served from an OCI image, define and test that image in the web-server or deployment repository. Validate non-root execution, static-asset integrity, compression and cache headers, entrypoint, health behavior, image size/layers, SBOM/provenance, signatures, and vulnerability results independently from mobile store releases.
