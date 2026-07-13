# Running the emulator Job on the cluster: the KVM-node requirement

The permission-test Job (`k8s/emulator-permission-test.job.yaml`) needs a
**KVM-capable node**. This is verified fact for the current cluster, not a
guess: the existing node (`ip-172-31-29-64.ec2.internal`, a virtualized EC2
instance) has **no `/dev/kvm`** — a privileged probe returned `NO_KVM`. A normal
virtualized EC2 / Hetzner-Cloud instance **cannot** expose nested virtualization,
so the emulator can only fall back to full software emulation (TCG), which boots
an x86 Android image in tens of minutes and is not reliable for CI.

The headless flow itself is already **proven green on a KVM host** — the
`android-emulator-test.yml` workflow booted a real emulator on GitHub's KVM
runner and the permission smoke-test passed. What remains is giving the *cluster*
a KVM node.

## Option A — AWS EC2 bare-metal node (nested virt / KVM)

This IS the AWS answer: the cluster already runs on AWS EC2, and regular EC2
instances run on the Nitro hypervisor which does **not** expose nested
virtualization. On AWS, KVM is available **only on `*.metal` instances** — for
EKS or self-managed k8s alike (a metal node simply joins as a bare-metal node
group). There is no non-metal AWS shortcut.

**Prefer ARM/Graviton metal + an arm64 Android image** — it runs *natively* with
KVM (no cross-arch penalty) and is far cheaper than x86 metal:

| Instance    | Arch | vCPU | RAM   | ~On-demand | Notes |
|-------------|------|------|-------|------------|-------|
| `a1.metal`  | ARM  | 16   | 32 GB | **~$0.41/hr** | cheapest KVM EC2; check region availability |
| `c6g.metal` | ARM  | 64   | 128 GB| ~$2.18/hr  | Graviton2, widely available |
| `c7g.metal` | ARM  | 64   | 128 GB| ~$2.90/hr  | Graviton3 |
| `c5.metal`  | x86  | 96   | 192 GB| ~$4.08/hr  | only if you specifically need x86 images |

For ARM nodes, build the image for arm64 and create the AVD from an **arm64-v8a**
system image:
```bash
docker buildx build --platform linux/arm64 \
  --build-arg ANDROID_ARCH=arm64-v8a \
  -f ci/android-emulator/Dockerfile -t ghcr.io/sonus-auris/android-emulator:arm64 .
```
(The Dockerfile derives JAVA_HOME from TARGETARCH, and the image build workflow
can add `linux/arm64` to `platforms`.)

Run the node **on demand for a test and tear it down**, or use a **spot** metal
instance (~60–70% cheaper) for CI bursts.

Steps:
1. Launch an `a1.metal` (or `c6g.metal`; spot recommended) in the cluster's
   VPC/subnet and join it to the k8s cluster (the cluster's `remote/ec2` /
   `remote/terraform` join flow).
2. Confirm KVM: `ssh` in, `ls -l /dev/kvm` (present on metal).
3. Label + taint so only emulator Jobs land there:
   ```bash
   kubectl label node <metal-node> sonus-auris.dev/kvm=true
   kubectl taint node <metal-node> sonus-auris.dev/kvm=true:NoSchedule
   ```
   (add a matching toleration to the Job if you taint.)

## Option B — Hetzner dedicated / root server

Hetzner **Cloud** shared vCPUs cannot do nested virt; a **dedicated/root** server
(e.g. an AX-line box, ~€40–110/mo) can. Provision it, install the container
runtime + kubelet, join the cluster, then label as above. Cheaper if you want a
persistent CI emulator node rather than on-demand bursts.

## Expose /dev/kvm to pods

Once a KVM node exists, pick one:

- **Device plugin (preferred, unprivileged):** install `smarter-device-manager`
  or KubeVirt's kvm device plugin so the node advertises
  `devices.kubevirt.io/kvm`. The Job already requests it.
- **Privileged + hostPath:** uncomment the `securityContext.privileged` +
  hostPath `/dev/kvm` block in the Job and drop the device-plugin resource line.

## Then run it

```bash
# image is built + pushed by .github/workflows/build-emulator-image.yml
kubectl create ns sonus-auris   # if absent
kubectl apply -f ci/android-emulator/k8s/emulator-permission-test.job.yaml
kubectl -n sonus-auris logs -f job/sonus-emulator-permission-test
```

## Recommendation

For **CI gating**, keep using the GitHub KVM runner (`android-emulator-test.yml`)
— it's free, fast, and already green. Add a cluster KVM node only if you
specifically need the test to run inside your own network/cluster (e.g. against
internal-only backends). If so, an **on-demand or spot `c5.metal`, torn down
after the run**, is the most cost-effective path.
