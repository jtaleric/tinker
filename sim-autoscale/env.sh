#!/usr/bin/env bash
# Shared configuration for the HyperShift + kubemark autoscaler lab.
# Source this file; do not execute it.
#
# Every value can be overridden from the environment, e.g.
#   HC_NAME=sim1 ./create-hostedcluster.sh

SIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SIM_ROOT

# --- cluster profile ----------------------------------------------------
# Multiple hosted clusters can coexist on this management cluster, each with a
# different OpenShift version. A profile is just a file of exports, sourced
# BEFORE the defaults below so that whatever it sets wins:
#
#   CLUSTER_PROFILE=sim419 ./create-hostedcluster.sh
#
# See profiles/*.env. Everything namespaced by HC_NAME is kept separate
# automatically, so profiles only need to set the version-specific bits.
if [[ -n "${CLUSTER_PROFILE:-}" ]]; then
  _profile="$SIM_ROOT/profiles/${CLUSTER_PROFILE}.env"
  if [[ -r "$_profile" ]]; then
    # shellcheck disable=SC1090
    source "$_profile"
  else
    echo "ERROR: no such cluster profile: $_profile" >&2
    return 1 2>/dev/null || exit 1
  fi
fi

# --- management cluster -------------------------------------------------
export KUBECONFIG="${KUBECONFIG:-$SIM_ROOT/kubeconfig}"
export BIN_DIR="${BIN_DIR:-$SIM_ROOT/bin}"
export HYPERSHIFT_BIN="${HYPERSHIFT_BIN:-$BIN_DIR/hypershift}"

# --- hosted cluster -----------------------------------------------------
export HC_NAME="${HC_NAME:-sim0}"

# Derived values below are EXPORTED, so a parent that sourced env.sh for one
# cluster leaks them into any child invoked for a different one: the profile
# sets HC_NAME=sim419 but an inherited HCP_NS=clusters-sim0 wins the
# ${VAR:-default} test, and manifests silently target the wrong namespace.
# Recompute whenever the cluster changes, while still honouring an override
# set deliberately for THIS cluster.
if [[ "${_SIM_DERIVED_FOR:-}" != "$HC_NAME" ]]; then
  unset HCP_NS HOLLOW_NS HC_KUBECONFIG GENERATED_DIR RESULTS_DIR INFRA_ID
fi
export _SIM_DERIVED_FOR="$HC_NAME"
export CLUSTERS_NS="${CLUSTERS_NS:-clusters}"
# HyperShift derives the control-plane namespace as <hc-namespace>-<hc-name>.
export HCP_NS="${HCP_NS:-${CLUSTERS_NS}-${HC_NAME}}"
# The CAPI Cluster object is named after infraID so that the kubeconfig secret
# HyperShift already creates (<infraID>-kubeconfig) resolves by CAPI convention.
export INFRA_ID="${INFRA_ID:-$HC_NAME}"
export BASE_DOMAIN="${BASE_DOMAIN:-sim.local}"

# OVNKubernetes is the default for realism. If hollow kubelets fail to reach
# Ready because of CNI (see README "Risk: hollow nodes and OVN"), set this to
# "Other" to skip CNI entirely.
export NETWORK_TYPE="${NETWORK_TYPE:-OVNKubernetes}"

# APIServer exposure. LoadBalancer provisions an AWS NLB using the management
# cluster's own credentials and needs no DNS work. Set to Route for zero cost.
# Neither affects the control loop: the autoscaler and CAPK use the in-cluster
# service address via <infraID>-kubeconfig.
export APISERVER_STRATEGY="${APISERVER_STRATEGY:-LoadBalancer}"

export ETCD_STORAGE_CLASS="${ETCD_STORAGE_CLASS:-gp3-csi}"
export ETCD_STORAGE_SIZE="${ETCD_STORAGE_SIZE:-8Gi}"

# Resolved at runtime from the management cluster if left empty.
export RELEASE_IMAGE="${RELEASE_IMAGE:-}"

# --- hypershift operator ------------------------------------------------
export HYPERSHIFT_IMAGE="${HYPERSHIFT_IMAGE:-quay.io/hypershift/hypershift-operator:latest}"

# --- kubemark / CAPK ----------------------------------------------------
export CAPK_VERSION="${CAPK_VERSION:-v0.12.0}"
export CAPK_NS="${CAPK_NS:-capk-system}"
export CAPK_COMPONENTS_URL="${CAPK_COMPONENTS_URL:-https://github.com/kubernetes-sigs/cluster-api-provider-kubemark/releases/download/${CAPK_VERSION}/infrastructure-components.yaml}"
# The v0.12.0 release manifest references the controller image by the floating
# ":latest" tag -- no versioned tag is published. Pin the digest it resolved to
# so runs stay reproducible. Override to track latest again.
export CAPK_CONTROLLER_IMAGE="${CAPK_CONTROLLER_IMAGE:-quay.io/cluster-api-provider-kubemark/cluster-api-kubemark-controller-amd64@sha256:c8fe0df736bab888eaa46578960db8461b8fae9ad3209038b8a62b3c75713b94}"
export KUBEMARK_IMAGE_REPO="${KUBEMARK_IMAGE_REPO:-quay.io/cluster-api-provider-kubemark/kubemark}"
# Selects the kubemark image tag AND the CAPI Machine version. Must match the
# hosted cluster's Kubernetes minor (OCP 4.22 -> k8s 1.35).
export KUBEMARK_VERSION="${KUBEMARK_VERSION:-v1.35.7}"
# Namespace (on this same management cluster) where hollow-node pods are
# placed, keeping them out of the hosted control-plane namespace. Derived from
# HC_NAME so that several hosted clusters do not share one pool of fake nodes
# -- which would make per-cluster control-plane cost impossible to attribute.
export HOLLOW_NS="${HOLLOW_NS:-${HC_NAME}-hollow}"
# kubemark runs with --use-host-image-service=true and hardcodes the containerd
# socket path, but OpenShift runs CRI-O. The hollow node therefore needs the
# CRI-O socket bind-mounted at the containerd path it expects, or it crashloops
# with "Failed to init image service". CRI-O also implements the CRI image API,
# so it satisfies kubemark once mounted at the expected location.
export CRI_SOCKET_HOST_PATH="${CRI_SOCKET_HOST_PATH:-/run/crio/crio.sock}"
export CRI_SOCKET_CONTAINER_PATH="${CRI_SOCKET_CONTAINER_PATH:-/run/containerd/containerd.sock}"

# --- workload driver ----------------------------------------------------
export DRIVER_NS="${DRIVER_NS:-scale-driver}"

# --- misc ---------------------------------------------------------------
export NODETYPES_FILE="${NODETYPES_FILE:-$SIM_ROOT/nodetypes.yaml}"
# Per-cluster so that parallel clusters do not overwrite each other's rendered
# manifests or observation CSVs.
export GENERATED_DIR="${GENERATED_DIR:-$SIM_ROOT/generated/$HC_NAME}"
export RESULTS_DIR="${RESULTS_DIR:-$SIM_ROOT/results/$HC_NAME}"
# Shared across clusters (CAPK release manifest, hypershift install render).
export SHARED_DIR="${SHARED_DIR:-$SIM_ROOT/generated/_shared}"
# Hosted cluster admin kubeconfig, written by create-hostedcluster.sh.
export HC_KUBECONFIG="${HC_KUBECONFIG:-$SIM_ROOT/${HC_NAME}-admin.kubeconfig}"

# DRY_RUN=1 renders manifests and validates them server-side without creating
# anything. RENDER=1 is stricter: it only prints, never contacting the API
# server to apply or validate, which allows fully offline checks.
export RENDER="${RENDER:-0}"
export DRY_RUN="${DRY_RUN:-0}"
# Must be an if, not `[[ ... ]] && ...`: the latter returns non-zero when the
# test is false, which aborts any caller running under `set -e`.
if [[ "$RENDER" == "1" ]]; then
  export DRY_RUN=1
fi

# --- patched HyperShift operator ----------------------------------------
# The stock operator cannot convert CAPI objects that reference Kubemark
# types: capiAPIVersionGetter resolves GroupKind->apiVersion purely from the
# operator's compiled-in runtime.Scheme, and CAPK is not registered there.
# Every v1beta1 read of a kubemark-backed Machine/MachineDeployment then
# fails with "no versions registered for GroupKind KubemarkMachineTemplate".
#
# Fix: one import + one AddToScheme in support/api/scheme.go. It adds type
# registration only and does not touch conversion logic, so conversion-cost
# measurements remain valid. Built in-cluster; see README "Patching the
# operator". Unset to go back to stock.
export HYPERSHIFT_IMAGE="${HYPERSHIFT_IMAGE:-image-registry.openshift-image-registry.svc:5000/hs-build/hypershift-operator-kubemark@sha256:b31b81ab1a172371263cb75959106e11bfb483c17507c1be3333db5ef7b6e712}"
