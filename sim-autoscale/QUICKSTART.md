# Quickstart

Stand up the lab and benchmark HyperShift's cluster-autoscaler.
See [README.md](README.md) for *why* each piece exists.

1. [Management cluster](#1-management-cluster)
2. [Prerequisites](#2-prerequisites)
3. [Patch and build HyperShift for kubemark](#3-patch-and-build-hypershift-for-kubemark)
4. [Install](#4-install)
5. [Create a hosted cluster](#5-create-a-hosted-cluster)
6. [Run benchmarks](#6-run-benchmarks)
7. [Reset and teardown](#7-reset-and-teardown)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Management cluster

Any self-managed OpenShift cluster. **No cloud credentials needed** — hosted
clusters use `platform: None` and every worker is fake.

Validated on OCP **4.22.22** (AWS): 3 × `m5.4xlarge` control plane,
3 × `m5.4xlarge` workers, 2 × `r5.4xlarge` infra, `gp3-csi` default.

Each hosted control plane costs ~2–3 cores / 6–8 GiB. Each fake node requests
40m CPU but really uses 50–150 MiB, so the binding limits are pods-per-node
(250 × workers) and real memory. On the above: **~800–1000 fake nodes**.

```bash
cp /path/to/kubeconfig ./kubeconfig
oc --kubeconfig ./kubeconfig whoami        # must be cluster-admin
```

## 2. Prerequisites

```bash
oc version --client
yq --version        # v4.x (mikefarah) -- NOT the python yq
jq --version
python3 -c "import jsonschema, yaml"
```

For building the patched operator: `go` matching HyperShift's `go.mod`
(1.26.3 at time of writing) and `podman`.

```bash
./verify.sh         # offline checks, creates nothing
```

## 3. Patch and build HyperShift for kubemark

**Required unless every hosted cluster is 4.22+.** Below 4.21 the stock
operator cannot convert kubemark-backed CAPI objects, and the failure is
silent: the autoscaler sets replicas, no MachineSet appears, nothing logs an
error.

```
no versions registered for GroupKind KubemarkMachineTemplate.infrastructure.cluster.x-k8s.io
```

`capiAPIVersionGetter` resolves GroupKind→apiVersion purely from the
operator's compiled-in `runtime.Scheme`. No RBAC, CRD or config change can fix
it — it needs a rebuilt binary.

```bash
./bin/hypershift version      # note the commit; match it

mkdir -p ../hypershift-src && cd ../hypershift-src
git clone --filter=blob:none https://github.com/openshift/hypershift.git
cd hypershift
git fetch --depth 1 origin <commit> && git checkout FETCH_HEAD

git apply ../../sim-autoscale/hypershift-kubemark-scheme.patch
export GOFLAGS=-mod=mod GOTOOLCHAIN=local
go get sigs.k8s.io/cluster-api-provider-kubemark@v0.12.0
go mod tidy && go mod vendor
```

The patch covers only `scheme.go` + `go.mod`; `go get`/`tidy`/`vendor` are
**not** optional.

Verify the scheme before building anything:

```bash
cat > schemecheck_test.go <<'EOF'
package main

import (
	"testing"

	"github.com/openshift/hypershift/support/api"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestKubemarkGroupKindResolves(t *testing.T) {
	for _, kind := range []string{"KubemarkMachineTemplate", "KubemarkMachine"} {
		gk := schema.GroupKind{Group: "infrastructure.cluster.x-k8s.io", Kind: kind}
		if v := api.Scheme.VersionsForGroupKind(gk); len(v) == 0 {
			t.Fatalf("%s: no versions registered", kind)
		} else {
			t.Logf("%s -> %s", kind, v[0])
		}
	}
}
EOF
GOFLAGS=-mod=vendor go test -run TestKubemarkGroupKindResolves -v .
rm schemecheck_test.go
```

Only `/usr/bin/hypershift-operator` serves the webhook, so build just that and
overlay it (~30 s, not a full image build):

```bash
GOFLAGS=-mod=vendor GOTOOLCHAIN=local CGO_ENABLED=0 \
  go build -o /tmp/hypershift-operator ./hypershift-operator
mkdir -p /tmp/hsimg && cp /tmp/hypershift-operator /tmp/hsimg/
printf 'FROM quay.io/hypershift/hypershift-operator:latest\nCOPY hypershift-operator /usr/bin/hypershift-operator\n' \
  > /tmp/hsimg/Dockerfile
```

### 3. In-cluster build

Keeps the registry internal; no external account, nothing exposed.

```bash
oc create namespace hs-build --dry-run=client -o yaml | oc apply -f -
oc -n hs-build new-build --binary --name=hypershift-operator-kubemark --strategy=docker
oc -n hs-build start-build hypershift-operator-kubemark --from-dir=/tmp/hsimg --follow

oc policy add-role-to-user system:image-puller \
  system:serviceaccount:hypershift:operator -n hs-build
IMG=$(oc -n hs-build get istag hypershift-operator-kubemark:latest \
        -o jsonpath='{.image.dockerImageReference}')
```

> The Docker strategy requires the file be named **`Dockerfile`**;
> `Containerfile` fails with `open /tmp/build/inputs/Dockerfile: no such file`.

### Use it

```bash
export HYPERSHIFT_IMAGE="$IMG"       # env.sh defaults to a prebuilt image
./install.sh
oc logs deploy/operator -n hypershift --since=2m | grep -c "no versions registered"   # expect 0
```

Rollback (hosted control planes keep running while the operator is down):

```bash
./bin/hypershift install --hypershift-image quay.io/hypershift/hypershift-operator:latest
```

## 4. Install

```bash
./install.sh                 # HyperShift operator + CAPK. Once per mgmt cluster.
./install.sh --crds-only     # just the CAPK CRDs
```

## 5. Create a hosted cluster

A profile is a file of exports in `profiles/`:

```bash
cat > profiles/sim419.env <<'EOF'
export HC_NAME=sim419
export RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.19.22-x86_64
export KUBEMARK_VERSION=v1.32.8
EOF

CLUSTER_PROFILE=sim419 ./create-hostedcluster.sh    # ~5 min
CLUSTER_PROFILE=sim419 ./wire-capi.sh
./cas-benchmark.sh status
```

**`KUBEMARK_VERSION` must match the hosted cluster's Kubernetes minor** — it
selects both the Machine's `spec.version` and the kubemark image tag.

| OpenShift | Kubernetes | kubemark tag | converts? |
|---|---|---|---|
| 4.19.22 | 1.32.10 | `v1.32.8` | yes (v1beta1 CAPI) |
| 4.20.41 | 1.33.13 | `v1.33.4` | yes |
| 4.21.43 | 1.34.x | `v1.34.3` | **no** (v1beta2-native) |
| 4.22.22 | 1.35.x | `v1.35.7` | no |

Confirm with
`oc adm release info <image> -o json | jq -r '.references.spec.tags[]|select(.name=="hyperkube").annotations["io.openshift.build.versions"]'`.
Patch levels need not match; the **minor must**.

Everything else derives from `HC_NAME`, so clusters never collide.

### Node groups

Edit `nodetypes.yaml` and re-run `wire-capi.sh`. One entry = one
`KubemarkMachineTemplate` + one `MachineDeployment` = **one autoscaler node
group** (the production equivalent of one NodePool).

```yaml
nodetypes:
  - name: m5-2xlarge-a
    cpu: "8"
    memory: "32G"
    zone: us-east-2a
    instanceType: m5.2xlarge
    min: 0        # floor for scale-DOWN; also clamps initial replicas
    max: 50
```

Or generate many at once:

```bash
./cas-benchmark.sh groups sim419 16
NODEGROUP_MAX_OVERRIDE=2000 ./cas-benchmark.sh groups sim419 4
```

Scale-from-zero relies on capacity annotations the generator writes
(`capacity.cluster-autoscaler.kubernetes.io/{cpu,memory,maxPods,labels}`).
The **labels** annotation has no other source — without it the autoscaler
cannot satisfy a zone or instance-type `nodeSelector` from zero, and silently
declines. Never group on `kubernetes.io/hostname`: that scales to infinity
against hostname anti-affinity.

## 6. Run benchmarks

```bash
./cas-benchmark.sh tune sim419              # do this FIRST, [rook]however doesn't always work to set the QPS
./cas-benchmark.sh basic sim419             # scale up, then down
./cas-benchmark.sh baseline sim419 100 4    # pin 100 nodes across 4 groups
./cas-benchmark.sh measure sim419           # loop timings
./cas-benchmark.sh breakpoint sim419 2 3 4 5
```

**`tune` first.** `kubeClientQPS` is unset by default, so CA runs at
client-go's 5 QPS and the rate limiter — not real work — dominates loop time.
`scaleDown` defaults of 10m unneeded + 10m delayAfterAdd also make one churn
cycle ~25 minutes. `tune` reports whether the args actually reached the
deployment; on 4.19/4.20 the QPS half is often silently inert (see
Troubleshooting).

**`breakpoint`** multipliers are **relative and compounding**: each step
demands `mult × current nodes`, re-read live. x16 does not mean 16 nodes. Use
gentle steps (`2 3 4 5`) — `1 2 4 8 16` can jump from 150 to 2400 nodes.
Each step runs up **and** down (`CHURN=1`), so scale-down is exercised too.

It stops on real failures — no completed loops, autoscaler restart, pods
pending while nodes flat, new errors — and reports **ceiling** separately when
every group is at `max`, which is correct behaviour rather than a break.

Reading the output: **`loops observed in window: 0`** means nothing was
measured; raise `WINDOW` above one loop time. Exceeding the 10 s scan interval
is a *warning* — decisions are stale but scaling still works.

## 7. Reset and teardown

```bash
./cas-benchmark.sh reset              # wipe machines, keep clusters + groups
./cas-benchmark.sh reset --hard       # also remove node groups
CLUSTER_PROFILE=sim419 ./teardown.sh  # remove the hosted cluster
```

`reset` caps `max-size=0` **before** scaling down — otherwise each hosted
cluster's own system pods trigger scale-up the instant a group hits 0 and you
never converge. The cap stays until you re-run `wire-capi.sh` or `groups`.

Never `oc delete machine` on MachineSet-owned machines; the MachineSet just
recreates them. Synthesized machines have no owner and need explicit deletion.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cluster-autoscaler` at `replicas: 0` | no NodePool has `spec.autoScaling`, so HyperShift sets `disable-cluster-autoscaler`. Checked by **existence**, not value | the enabler NodePool in `create-hostedcluster.sh`; editing the annotation is reverted |
| Autoscaler scales but **no MachineSet** | missing `rollout.strategy.type`, or a conversion failure | set strategy; check `oc get machinedeployment.v1beta1... 2>&1 \| grep conversion` |
| `nil value for IntOrString` | `maxSurge`/`maxUnavailable` unset | set both explicitly |
| Hollow pod crashloops, "Failed to init image service" | kubemark hardcodes containerd; OpenShift runs CRI-O | `extraMounts` maps `/run/crio/crio.sock` (already in `gen-nodetypes.sh`) |
| Hollow pod Running, **no Node registers** | `<infraID>-kubeconfig` uses unqualified `kube-apiserver:6443` | the `ExternalName` alias in `wire-capi.sh` |
| Machines stuck `Provisioned`, empty `nodeRef` | CAPI not woken when the Node registers | `nudge_pending_machines` in `lib.sh` |
| CAPK `OOMKilled`, nothing reconciles | upstream limits 30Mi/100m vs an all-namespace watch caching every Secret | raised to 1Gi/1 CPU in `install.sh` |
| Whole namespace stops reconciling | one unconvertible object fails the entire LIST | patch the operator (§3) |
| `min` set but **no nodes created** | CA never scales UP to satisfy min — it is a scale-DOWN floor only | `gen-nodetypes.sh` clamps `replicas = max(current, min)`; re-run `wire-capi.sh` |
| `tune` sets QPS but args never appear | HyperShift only **replaces** an existing `--kube-client-qps=`; the hosted cluster's own CPO predates it | use 4.22+, or patch the deployment directly and accept CPO reconciliation |
| `oc get clusters` `AVAILABLE=False`, `W AVAILABLE=0` with Ready nodes | no `controlPlaneRef` | `wire-capi.sh` points it at the `HostedControlPlane` |
| `AVAILABLE=Unknown`, `InfrastructureReady=Unknown` | `platform: None` has no infra CR | expected and harmless |
| HostedCluster `PROGRESS=Partial` | hosted CVO can never complete without real nodes | expected; check `Available=True` |
| Cluster-wide pending pods never reach 0 | one `openshift-ingress-canary` per node, never schedulable | expected; count only the driver namespace |
