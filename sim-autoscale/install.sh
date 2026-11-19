#!/usr/bin/env bash
# One-time setup of the management cluster: HyperShift operator + CAPK.
# Run once per management cluster, not per hosted cluster.
#
#   ./install.sh                 # install both
#   ./install.sh --crds-only     # just the CAPK CRDs
#
# NOTE ON THE OPERATOR IMAGE
# The stock HyperShift operator cannot convert CAPI objects that reference
# Kubemark types: capiAPIVersionGetter resolves GroupKind -> apiVersion purely
# from the operator's compiled-in runtime.Scheme, and CAPK is not registered
# there. Every v1beta1 read of a kubemark-backed Machine then fails with
# "no versions registered for GroupKind KubemarkMachineTemplate", which breaks
# hosted clusters older than 4.21 entirely (one unconvertible object poisons
# the whole LIST, so CAPI creates no MachineSets at all).
#
# hypershift-kubemark-scheme.patch fixes that in three lines. Build it per
# QUICKSTART "Patch and build HyperShift for kubemark" and point
# HYPERSHIFT_IMAGE at the result. env.sh defaults to an already-built image.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source ./env.sh
# shellcheck source=lib.sh
source ./lib.sh

need_cmd oc yq curl
need_cluster

CRDS_ONLY=0
[[ "${1:-}" == "--crds-only" ]] && CRDS_ONLY=1

mkdir -p "$BIN_DIR" "$SHARED_DIR"

# --- 1. hypershift CLI --------------------------------------------------
if [[ "$CRDS_ONLY" == "0" ]]; then
  if [[ -x "$HYPERSHIFT_BIN" ]]; then
    ok "hypershift CLI present: $HYPERSHIFT_BIN"
  else
    log "extracting hypershift CLI from $HYPERSHIFT_IMAGE"
    oc image extract "$HYPERSHIFT_IMAGE" \
      --filter-by-os=linux/amd64 \
      --path "/usr/bin/hypershift:${BIN_DIR}" --confirm
    chmod +x "$HYPERSHIFT_BIN"
  fi

  # --- 2. operator ------------------------------------------------------
  if [[ "$DRY_RUN" == "1" ]]; then
    log "(dry-run) rendering hypershift install manifests"
    "$HYPERSHIFT_BIN" install render --hypershift-image "$HYPERSHIFT_IMAGE" --format=yaml
  else
    if oc get deployment operator -n hypershift >/dev/null 2>&1; then
      ok "HyperShift operator already installed"
    else
      log "installing HyperShift operator ($HYPERSHIFT_IMAGE)"
      "$HYPERSHIFT_BIN" install --hypershift-image "$HYPERSHIFT_IMAGE"
    fi
    wait_for 300 "HyperShift operator available" \
      oc wait --for=condition=Available --timeout=10s deployment/operator -n hypershift
    # CAPI CRDs arrive with the operator; later steps validate against them.
    for crd in clusters.cluster.x-k8s.io machinedeployments.cluster.x-k8s.io; do
      wait_for 120 "CRD $crd established" \
        oc wait --for=condition=Established --timeout=10s "crd/$crd"
    done
  fi
fi

# --- 3. CAPK ------------------------------------------------------------
COMPONENTS="$SHARED_DIR/capk-infrastructure-components.yaml"
if [[ ! -s "$COMPONENTS" ]]; then
  log "downloading CAPK ${CAPK_VERSION}"
  curl -fsSL -o "$COMPONENTS" "$CAPK_COMPONENTS_URL"
fi

log "applying CAPK CRDs"
yq -r 'select(.kind=="CustomResourceDefinition")' "$COMPONENTS" | kapply
if [[ "$DRY_RUN" != "1" ]]; then
  for crd in kubemarkmachines.infrastructure.cluster.x-k8s.io \
             kubemarkmachinetemplates.infrastructure.cluster.x-k8s.io; do
    wait_for 120 "CRD $crd established" \
      oc wait --for=condition=Established --timeout=10s "crd/$crd"
  done
fi

if [[ "$CRDS_ONLY" == "1" ]]; then
  ok "CRDs only -- stopping here"
  exit 0
fi

kapply <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CAPK_NS}
EOF

log "applying CAPK RBAC"
yq -r 'select(.kind!="CustomResourceDefinition" and .kind!="Deployment" and .kind!="Namespace" and .kind!=null)' \
  "$COMPONENTS" | kapply

# Upstream grants pods create,delete but not get/list/watch, so the
# controller cannot read back the hollow-node pods it owns.
kapply <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: capk-manager-pods-read
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/status"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: capk-manager-pods-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: capk-manager-pods-read
subjects:
  # CAPK ships no ServiceAccount of its own; its Deployment leaves
  # serviceAccountName empty and upstream binds to ServiceAccount/default.
  - kind: ServiceAccount
    name: default
    namespace: ${CAPK_NS}
EOF

# Upstream limits are 30Mi/100m, sized for a single-namespace watch. Watching
# ALL namespaces (required to serve every hosted cluster) makes the informer
# cache every Machine, Cluster and -- because the upstream ClusterRole grants
# cluster-wide secret access -- every Secret on the management cluster. At
# 30Mi that is an immediate OOMKill loop: the pod never acquires the leader
# lease and NOTHING reconciles, with no error anywhere.
CAPK_MEM_LIMIT="${CAPK_MEM_LIMIT:-1Gi}"
CAPK_CPU_LIMIT="${CAPK_CPU_LIMIT:-1}"

log "applying CAPK controller (digest-pinned, all namespaces, ${CAPK_CPU_LIMIT}/${CAPK_MEM_LIMIT})"
yq -r 'select(.kind=="Deployment")' "$COMPONENTS" \
  | yq -r "
      .spec.template.spec.containers |= map(
        select(.name==\"manager\").image = \"${CAPK_CONTROLLER_IMAGE}\" |
        select(.name==\"manager\").args += [\"--kubemark-image=${KUBEMARK_IMAGE_REPO}\"] |
        select(.name==\"manager\").resources.limits.memory = \"${CAPK_MEM_LIMIT}\" |
        select(.name==\"manager\").resources.limits.cpu = \"${CAPK_CPU_LIMIT}\" |
        select(.name==\"manager\").resources.requests.memory = \"256Mi\" |
        select(.name==\"manager\").resources.requests.cpu = \"200m\"
      )" \
  | kapply

if [[ "$DRY_RUN" != "1" ]]; then
  wait_for 300 "CAPK controller available" \
    oc wait --for=condition=Available --timeout=10s \
      deployment/capk-controller-manager -n "$CAPK_NS"
fi

ok "install complete -- next: ./create-hostedcluster.sh"
