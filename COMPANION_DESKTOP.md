# Companion desktop implementation

This repository is the **live Flutter product implementation** for Sonus Auris across mobile and native desktop targets.

## Canonical pair

- Flutter: [`sonus-auris/sonus-auris-flutter.dart`](https://github.com/sonus-auris/sonus-auris-flutter.dart) — **live**; this repository.
- Rust: [`sonus-auris/sonus-auris-desktop.rs`](https://github.com/sonus-auris/sonus-auris-desktop.rs) — **live**; the canonical pure-Rust desktop recorder and viewer implementation.

The additional Flutter device console is consolidated into this repository at
`apps/console`. The former `sonus-auris-web-desktop.dart` repository is
deprecated.

## Feature-delivery contract

For every desktop-facing feature:

1. inspect both canonical implementations before deciding scope;
2. define shared acceptance criteria and identify affected APIs, schemas, clients, assets, fixtures, encryption formats, and device behavior;
3. update both canonical repositories, or record an explicit implementation-specific no-change rationale;
4. assess whether `apps/console` also needs a corresponding change;
5. test and report Rust and Flutter status separately; and
6. keep reciprocal repository references current.

Semantic product parity is required; internal architecture and platform-native behavior may differ.

## Project routing

- GitHub Project: [`sonus-auris-project` — Project 1](https://github.com/orgs/sonus-auris/projects/1)
- Canonical portfolio registry: [`ORESoftware/project-registry`](https://github.com/ORESoftware/project-registry/blob/main/registry/desktop-applications.json)
- Linear rollout: [`DEN-2469`](https://linear.app/denman/issue/DEN-2469/roll-out-paired-rust-flutter-desktop-repositories-across-the-portfolio)

When repository ownership, naming, or status changes, update this file, the companion repositories, the organization documentation, and the central registry in the same delivery.
