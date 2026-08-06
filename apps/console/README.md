# Sonus Auris console

Flutter console for viewing and controlling Sonus Auris devices. It targets the
web and native Linux, macOS, and Windows desktops. It was consolidated from
`sonus-auris-web-desktop.dart` and now lives alongside the recorder in the
canonical `sonus-auris-flutter.dart` repository.

The console calls `api.sonusauris.app` using the signed-in user's identity. It
must never receive database credentials, provider secrets, internal-worker
secrets, or a Supabase service-role key. The canonical browser account site at
`user.sonusauris.app` is served by `sonus-auris-web-server.rs`; this package is
the Flutter-native/web console surface.

## Verify locally

```sh
cd apps/console
flutter pub get
flutter analyze
flutter test
flutter build web --release
```

Browser smokes live in `e2e/` and run the same assertions through Puppeteer and
Playwright. See [e2e/README.md](e2e/README.md).

## Delivery

- GitHub Actions builds the web bundle on every change and native desktop
  bundles from the repository-root workflows.
- The production web console is declared in the `k8s-cluster` repository and
  reconciled by Argo CD; this repository never deploys directly to Kubernetes.
- Native artifacts are currently unsigned test bundles. Signing, notarization,
  installer creation, and update feeds are explicit release follow-ups.

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the build/test matrix and
promotion process.
