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

Only `*.metal` instances expose KVM. Cheapest sensible choices:

| Instance   | vCPU | RAM   | ~On-demand (us-east-1) |
|------------|------|-------|------------------------|
| `c5.metal` | 96   | 192 GB| ~$4.08/hr              |
| `c6i.metal`| 128  | 256 GB| ~$5.44/hr              |
| `m5.metal` | 96   | 384 GB| ~$4.60/hr              |

These are large/expensive — run the node **on demand for a test run and tear it
down**, or use a **spot** metal instance (~60–70% cheaper) for CI bursts. There
is no small/cheap KVM EC2 option; bare-metal is the floor.

Steps:
1. Launch a `c5.metal` (spot recommended) in the cluster's VPC/subnet, same AMI
   as the existing node, and join it to the k8s cluster (the cluster's
   `remote/ec2` / `remote/terraform` join flow).
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
