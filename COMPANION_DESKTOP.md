# Related desktop implementations

This repository is the **live Flutter web/native device console** for Sonus Auris. It is an additional operator surface, not the sole Flutter half of the canonical dual-desktop product pair.

## Canonical product pair

- Rust: [`sonus-auris/desktop.app.rs`](https://github.com/sonus-auris/desktop.app.rs) — **live** pure-Rust desktop recorder/viewer.
- Flutter: [`sonus-auris/sonus-auris-ui.dart`](https://github.com/sonus-auris/sonus-auris-ui.dart) — **live** canonical Flutter mobile/desktop product application.
- Console: [`sonus-auris/sonus-auris-web-desktop.dart`](https://github.com/sonus-auris/sonus-auris-web-desktop.dart) — **live**; this repository.

## Feature-delivery contract

For console work that changes desktop-visible behavior, device control, authentication, recording state, playback, encryption, storage, or shared contracts:

1. inspect the Rust and canonical Flutter product implementations;
2. define shared acceptance criteria and identify affected APIs, schemas, clients, assets, and fixtures;
3. update every affected repository or record an explicit no-change rationale;
4. test and report console, Rust, and Flutter status separately; and
5. keep all reciprocal repository references current.

Semantic behavior should remain compatible while each surface preserves framework-native architecture and its own operator role.

## Project routing

- GitHub Project: [`sonus-auris-project` — Project 1](https://github.com/orgs/sonus-auris/projects/1)
- Canonical portfolio registry: [`ORESoftware/project-registry`](https://github.com/ORESoftware/project-registry/blob/main/registry/desktop-applications.json)
- Linear rollout: [`DEN-2469`](https://linear.app/denman/issue/DEN-2469/roll-out-paired-rust-flutter-desktop-repositories-across-the-portfolio)

When repository ownership, naming, or status changes, update this file, both canonical product repositories, the organization documentation, and the central registry in the same delivery.
