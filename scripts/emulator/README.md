# scripts/emulator

- **[permission-smoke.sh](permission-smoke.sh)** — headless Android permission
  smoke-test. Installs the app, launches it, and exercises every runtime
  permission the way a store reviewer would: it grants the mic/notification path
  and confirms the sensitive context permissions (location / Bluetooth /
  nearby-Wi-Fi) default to **denied / opt-in**, failing if the app crashes.

Runs identically against a locally booted emulator or the containerised CI
runner — see [../../ci/android-emulator/README.md](../../ci/android-emulator/README.md)
for the Docker/k8s harness and the KVM constraints.
