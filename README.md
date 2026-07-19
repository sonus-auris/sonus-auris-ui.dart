# Sonus Auris console

Flutter console for viewing and controlling Sonus Auris devices. It targets the
web and native Linux, macOS, and Windows desktops.

## Verify locally

```sh
flutter pub get
flutter analyze
flutter test
flutter build web --release
```

Browser smokes live in `e2e/` and run the same assertions through Puppeteer and
Playwright. See [e2e/README.md](e2e/README.md).

## Delivery

- GitHub Actions builds the web bundle on every change and native desktop
  bundles on their host operating systems.
- The production web console is declared in the `k8s-cluster` repository and
  reconciled by Argo CD; this repository never deploys directly to Kubernetes.
- Native artifacts are currently unsigned test bundles. Signing, notarization,
  installer creation, and update feeds are explicit release follow-ups.

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the build/test matrix and
promotion process.
