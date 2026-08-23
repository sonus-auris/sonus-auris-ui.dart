# Headless Android emulator — permission testing

This image runs the Sonus Auris permission smoke test on a real headless Android
emulator. The test (`scripts/emulator/permission-smoke.sh`) installs the exact
APK embedded in the image, launches it, and verifies that:

- sensitive context permissions such as location, Bluetooth, and nearby Wi-Fi
  remain denied until the user opts in;
- `RECORD_AUDIO` and `POST_NOTIFICATIONS` can be granted cleanly; and
- the application stays alive after the permission transition.

## KVM requirement

An Android emulator needs hardware virtualization. On Linux that means
`/dev/kvm`, available only on KVM-capable nodes such as AWS metal instances or
Hetzner dedicated/root servers. Shared cloud VMs generally do not expose nested
virtualization. Label an eligible Kubernetes node:

```bash
kubectl label node NODE sonus-auris.dev/kvm=true
```

Expose KVM with a device plugin when possible. The checked-in Job keeps the
privileged hostPath alternative commented out so enabling it remains an explicit
operator decision.

An iOS Simulator requires macOS and is validated separately by the iOS workflow.

## Build and inspect locally

Build the same debug APK contract used by CI, record its digest, and pass that
digest into BuildKit:

```bash
flutter pub get
flutter build apk --debug \
  --dart-define=SONUS_BACKEND_BASE_URL=http://127.0.0.1:8126 \
  --dart-define=SONUS_SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_compile_only

apk=build/app/outputs/flutter-apk/app-debug.apk
apk_sha256="$(sha256sum "$apk" | awk '{print $1}')"

docker build \
  --file ci/android-emulator/Dockerfile \
  --build-arg "VCS_REF=$(git rev-parse HEAD)" \
  --build-arg "APK_SHA256=$apk_sha256" \
  --tag sonus-android-emulator:local \
  .

docker image inspect sonus-android-emulator:local \
  --format '{{ index .Config.Labels "app.sonusauris.apk.sha256" }}'
```

On a KVM-capable Linux host, retain screenshots outside the image without
hiding the baked APK:

```bash
mkdir -p ci-out
docker run --rm --device /dev/kvm \
  --env SMOKE_SCREENSHOT=/evidence/permission-smoke.png \
  --volume "$PWD/ci-out:/evidence" \
  sonus-android-emulator:local
```

## GitHub Actions contract

`.github/workflows/build-emulator-image.yml` has four independent boundaries:

1. **policy** runs the dependency-free shell and cross-file supply-chain tests;
2. **verify-image** builds the exact PR APK and locally loads/inspects the image
   without registry credentials or `packages: write`;
3. **publish-image** runs only for trusted non-PR events, publishes
   `sha-<commit>` plus the convenience `latest` tag, emits provenance and SBOM
   attestations, and records the immutable image digest; and
4. **cluster-permission-test** renders and runs the Kubernetes Job with that
   exact digest when the base64 `KUBECONFIG_DATA` secret is configured.

The `latest` tag is never consumed by the cluster Job. It is only a convenience
pointer for humans.

## Run the immutable image on Kubernetes

The checked-in Job is a template and cannot be applied directly. Render it with
the exact digest emitted by the trusted publication job:

```bash
image_ref='ghcr.io/sonus-auris/android-emulator@sha256:REPLACE_WITH_64_HEX'
rendered="$(mktemp)"

bash scripts/emulator/render-k8s-job.sh \
  ci/android-emulator/k8s/emulator-permission-test.job.yaml \
  "$rendered" \
  "$image_ref"

kubectl -n sonus-auris delete job sonus-emulator-permission-test \
  --ignore-not-found --wait=true
kubectl apply -f "$rendered"
kubectl -n sonus-auris wait --for=condition=complete \
  job/sonus-emulator-permission-test --timeout=35m
kubectl -n sonus-auris logs job/sonus-emulator-permission-test \
  --all-containers=true
```

The renderer accepts only the canonical GHCR repository with a lowercase
64-hex SHA-256 digest, refuses mutable tags and malformed templates, writes
atomically, and gives the rendered manifest mode `0600`.
