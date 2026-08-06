# Console build, test, and deployment

Last reviewed: July 18, 2026.

## Automated matrix

| Surface | Runner | Checks and output |
|---|---|---|
| Flutter web | GitHub Linux and the cluster build server | analyze, unit tests, release bundle |
| Browser E2E | GitHub Linux and the cluster build server | Puppeteer + Playwright against the real web bundle |
| Linux desktop | GitHub Linux and cluster profile | release bundle |
| macOS desktop | GitHub-hosted macOS 15 | unsigned `.app` evidence bundle |
| Windows desktop | GitHub-hosted Windows | unsigned release directory |

Workflows pin Flutter 3.44.2 and use lockfile installs for the Node browser
harness. Pull requests run the Linux/web gates; macOS and Windows run after a
main-branch change or a manual dispatch to control native-runner cost.

## Argo GitOps deployment

The web console is hosted by `dd-sonus-auris-console` in
`~/codes/ores/k8s-cluster/remote/argocd/dd-next-runtime`. Its Deployment pins an
exact `sonus-auris-flutter.dart` commit SHA, builds `apps/console` with the
pinned Flutter image in an init container, and serves the immutable result from
an unprivileged, read-only nginx container. The cluster gateway exposes it at
`/sonus-console/`.

Promotion is intentionally declarative:

1. Merge and push a green `sonus-auris-flutter.dart` commit.
2. Update `SONUS_AURIS_CONSOLE_GIT_REF` and the revision annotation in the Argo
   Deployment to that exact commit.
3. Review and push the `k8s-cluster` change on `dev`.
4. Let Argo reconcile; verify the Deployment rollout, `/healthz`, the public
   route, and both browser smokes against the deployed URL.

Do not put a direct `kubectl apply` deployment step in this repository. Build
jobs produce evidence; the Argo repository owns live desired state.

## Production follow-ups

- If the Flutter web console remains hosted, give it an explicit secondary
  client hostname or path. `user.sonusauris.app` is reserved for the canonical
  passwordless `sonus-auris-web-server.rs` account site.
- Replace the temporary path URL in E2E with the Sonus hostname.
- Add macOS Developer ID signing, notarization, and a signed installer.
- Add Windows code signing and an MSIX installer.
- Decide a signed desktop update channel; keep unsigned CI bundles as test-only
  artifacts until then.
- Publish build provenance and checksums with each signed desktop release.
