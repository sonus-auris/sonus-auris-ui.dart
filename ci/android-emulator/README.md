# Headless Android emulator — permission testing

Runs the Sonus Auris **permission smoke-test** on a real Android emulator with no
display, so it can run in CI and on the cluster. The test
(`scripts/emulator/permission-smoke.sh`) installs the app, launches it, and
asserts:

- the sensitive **context permissions** (location, Bluetooth, nearby-Wi-Fi)
  default to **denied / opt-in** (a store-review expectation for a mic app),
- `RECORD_AUDIO` / `POST_NOTIFICATIONS` grant cleanly (the reviewer "allow" path),
- the app **does not crash** after grants and stays running.

## The KVM constraint (important)

An Android emulator needs hardware virtualization. On a dev Mac that's HVF
(built in). On **Linux** it's **KVM** (`/dev/kvm`), which is only available on:

- **AWS**: `*.metal` instances (e.g. `c5.metal`). Regular EC2 vCPUs do **not**
  expose nested virtualization.
- **Hetzner**: **dedicated / root** servers. Hetzner Cloud shared vCPUs can't.

**iOS note:** iOS Simulators require macOS and cannot run on Linux/k8s at all —
those tests run on macOS CI runners (see `.github/workflows/ios-build.yml`).

## Run locally (Mac, against your own emulator)

```bash
# boot any AVD headless, then:
flutter build apk --debug
scripts/emulator/permission-smoke.sh build/app/outputs/flutter-apk/app-debug.apk <serial>
```

## Run locally in Docker (Linux host with /dev/kvm)

```bash
flutter build apk --release   # or --debug
docker build -f ci/android-emulator/Dockerfile -t sonus-android-emulator .
docker run --rm --device /dev/kvm \
  -v "$PWD/build/app/outputs/flutter-apk/app-debug.apk:/work/app-release.apk:ro" \
  -v "$PWD/ci-out:/work" \
  sonus-android-emulator
# -> exit 0 on pass; /work/permission-smoke.png is an evidence screenshot.
```

## Run on the cluster (Hetzner / EC2)

1. Label a KVM-capable node: `kubectl label node <node> sonus-auris.dev/kvm=true`.
2. Expose `/dev/kvm` — install a KVM device plugin (advertises
   `devices.kubevirt.io/kvm`) **or** use the privileged/hostPath fallback noted
   in the Job manifest.
3. Build & push the image to `ghcr.io/sonus-auris/android-emulator` (bake the APK
   in, or add an initContainer that fetches it), then:

```bash
kubectl apply -f ci/android-emulator/k8s/emulator-permission-test.job.yaml
kubectl -n sonus-auris logs -f job/sonus-emulator-permission-test
```

The Job fails (non-zero) if any permission assertion fails or the app crashes,
so it can gate a release pipeline.
