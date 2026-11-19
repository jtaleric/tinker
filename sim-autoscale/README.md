# sim-autoscale

Benchmark **HyperShift's own cluster-autoscaler** against fake (kubemark) nodes,
with **reduced EC2 spend**.

## Scripts

| | |
|---|---|
| `install.sh` | one-time: HyperShift operator + CAPK |
| `create-hostedcluster.sh` | create a `platform: None` hosted cluster |
| `wire-capi.sh` | CAPI scaffolding + node groups for one cluster |
| `cas-benchmark.sh` | **all workloads and measurement** |
| `teardown.sh` | remove a hosted cluster |
| `verify.sh` | offline checks; creates nothing |
| `gen-nodetypes.sh` | renders node groups from `nodetypes.yaml` |

`env.sh` / `lib.sh` are sourced, not run. `profiles/*.env` select a cluster.

```bash
./install.sh                                        # once
CLUSTER_PROFILE=sim419 ./create-hostedcluster.sh
CLUSTER_PROFILE=sim419 ./wire-capi.sh
./cas-benchmark.sh basic sim419
```

## cas-benchmark

```
Workloads
  basic      <cluster>                   scale up, then down -- sanity check
  baseline   <cluster> <nodes> [groups]  pin a stable starting population
  breakpoint <cluster> [mult...]         ramp up+down until something fails

Operations
  status     [cluster]                   fleet inventory, or one cluster
  measure    <cluster>                   autoscaler loop timings
  groups     <cluster> <count>           set the number of node groups
  tune       <cluster> [qps] [burst] [s] raise client QPS, shorten scale-down
  reset      [--hard]                    wipe machines fleet-wide
```

Tunables: `SETTLE`, `WINDOW`, `POD_CPU`, `CPU_PER_NODE`, `CHURN`,
`CHURN_FLOOR_PCT`, `NODEGROUP_MIN_OVERRIDE`, `NODEGROUP_MAX_OVERRIDE`.

## How it works

HyperShift runs a cluster-autoscaler on **every** HostedCluster, including
`platform: None` — the predicate checks only the `DisableMachineManagement`
annotation, a reported kubeconfig and the CAPI kubeconfig secret. **No platform
gate.** Its args include:

```
--cloud-provider=clusterapi
--node-group-auto-discovery=clusterapi:namespace=$(MY_NAMESPACE)
```

No label filter, no NodePool coupling — so **any** MachineDeployment we create
in the control-plane namespace carrying the autoscaler min/max annotations is
discovered and scaled by the real product autoscaler.

```
pending pod
  → cluster-autoscaler        (HyperShift's own)
  → MachineDeployment         ← "node group". CA scales THIS.
  → MachineSet → Machine      (CAPI core)
  → KubemarkMachine           (CAPK controller)
  → hollow pod (/kubemark)    → Node registers in the hosted cluster
```

**CAPK** is the Cluster API *provider* (one controller). **kubemark** is the
fake-kubelet binary (one pod per fake node, real kubelet against a fake
runtime). Different things, confusingly similar names.

## What stresses the autoscaler

Every loop re-evaluates everything, so cost grows on three axes:

| axis | shows up as |
|---|---|
| **node-group count** | `cloudProviderRefresh`, scale-up simulation per group |
| node count | `findUnneeded` (scale-down evaluation) |
| pending pods | `filterOutSchedulable` |

Headline metric is `function_duration{function="main"}` — one full loop.
Past the 10 s scan interval the autoscaler is permanently behind.

Measured here: **~1.9 s of loop time per node group**, and already **25% over
budget while idle at 4 groups and 1 node**.

## Findings worth knowing

**The operator needs patching for kubemark.** `capiAPIVersionGetter` resolves
GroupKind→apiVersion purely from the compiled-in `runtime.Scheme`, and CAPK
is not registered there. Every v1beta1 read of a kubemark-backed Machine fails
with `no versions registered for GroupKind KubemarkMachineTemplate`, and **one
unconvertible object poisons the entire LIST**, so CAPI creates no MachineSets
at all. Fatal on hosted clusters below 4.21. `hypershift-kubemark-scheme.patch`
fixes it in three lines — see QUICKSTART.

**`min-size` does not create nodes.** The autoscaler only adds nodes for
*pending pods*; `min` is a floor for scale-DOWN only. A group at `replicas=0`
with `min=5` stays at 0 forever. `gen-nodetypes.sh` therefore clamps
`replicas = max(current, min)`.

**`kubeClientQPS` is silently inert on older clusters.** HyperShift only
*replaces* an existing `--kube-client-qps=` arg, never appends one. If the
hosted cluster's control-plane-operator (which comes from **its** release
payload, not the management cluster) predates that arg, the API field does
nothing. CA then runs at client-go's 5 QPS and the rate limiter dominates
loop time. `scaleDown.*` settings do apply.

**You cannot drain to zero while the autoscaler runs.** Each hosted cluster's
own system pods trigger scale-up the moment a group hits 0. `reset` caps
`max-size=0` first.

**Conversion only happens below 4.21.** CAPI CRDs are served v1beta1+v1beta2
with v1beta2 storage; 4.19/4.20 CAPI reads v1beta1 and converts, 4.21+ is
native and converts nothing. `apiserver_conversion_webhook_*` carries no
webhook identity and sums every webhook on the cluster — use
`controller_runtime_webhook_requests_total{webhook="/convert"}` instead.

## Caveats

- With no real nodes the hosted CVO never completes; `console`, `dns`,
  `monitoring`, `network`, `service-ca` stay down. Check `Available=True` on
  the HostedCluster, not ClusterOperators.
- `openshift-ingress-canary` leaves one permanently-pending pod **per node**,
  so cluster-wide pending counts are meaningless. `cas-benchmark` counts only
  the driver namespace.
- kubemark fakes the container runtime: no image pulls, CSI, or CNI datapath.
  This measures decision-making and control-plane load, not provisioning.
