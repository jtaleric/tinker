#!/usr/bin/env bash
# Tear the lab down in reverse order. Idempotent.
#
#   ./teardown.sh          # remove the lab, keep the HyperShift operator
#   ./teardown.sh --all    # also uninstall the HyperShift operator and CAPK CRDs
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source ./env.sh
# shellcheck source=lib.sh
source ./lib.sh

need_cmd oc
need_cluster

ALL=0
[[ "${1:-}" == "--all" ]] && ALL=1

# --- driver workload ----------------------------------------------------
if [[ -r "$HC_KUBECONFIG" ]]; then
  log "removing driver workload from the hosted cluster"
  hoc delete namespace "$DRIVER_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

# --- node groups --------------------------------------------------------
# MachineDeployments first so the autoscaler and CAPK wind machines down
# before the scaffolding they depend on disappears.
# MachineDeployments carry a CAPI finalizer that is only cleared while the
# owning Cluster still exists, so they must go first -- and even then a plain
# delete can hang, hence force_delete.
log "removing node groups"
if [[ "$DRY_RUN" != "1" ]]; then
  for md in $(oc get machinedeployment -n "$HCP_NS" -o name 2>/dev/null | cut -d/ -f2); do
    force_delete 120 machinedeployment "$md" -n "$HCP_NS"
  done

  log "waiting for machines to drain"
  for _ in $(seq 1 30); do
    n="$(oc get machines -n "$HCP_NS" --no-headers 2>/dev/null | grep -c . || true)"
    if [[ "${n:-0}" == "0" ]]; then break; fi
    sleep 5
  done

  for mt in $(oc get kubemarkmachinetemplate -n "$HCP_NS" -o name 2>/dev/null | cut -d/ -f2); do
    force_delete 30 kubemarkmachinetemplate "$mt" -n "$HCP_NS"
  done
fi

# --- CAPI scaffolding ---------------------------------------------------
log "removing CAPI scaffolding"
kdelete cluster "$INFRA_ID" -n "$HCP_NS" >/dev/null 2>&1 || true
kdelete secret "${INFRA_ID}-ca" -n "$HCP_NS" >/dev/null 2>&1 || true
kdelete secret kubemark-bootstrap -n "$HCP_NS" >/dev/null 2>&1 || true
kdelete secret hollow-pod-placement -n "$HCP_NS" >/dev/null 2>&1 || true

# --- CAPK + hollow nodes ------------------------------------------------
log "removing CAPK and hollow-node namespace"
kdelete namespace "$HOLLOW_NS" --wait=false >/dev/null 2>&1 || true
if [[ -s "$GENERATED_DIR/capk-infrastructure-components.yaml" && "$DRY_RUN" != "1" ]]; then
  if [[ "$ALL" == "1" ]]; then
    oc delete -f "$GENERATED_DIR/capk-infrastructure-components.yaml" --ignore-not-found >/dev/null 2>&1 || true
  else
    # Keep the CRDs so a re-run does not have to re-establish them.
    yq -r 'select(.kind!="CustomResourceDefinition" and .kind!=null)' \
      "$GENERATED_DIR/capk-infrastructure-components.yaml" \
      | oc delete --ignore-not-found -f - >/dev/null 2>&1 || true
  fi
fi
kdelete clusterrole capk-manager-pods-read >/dev/null 2>&1 || true
kdelete clusterrolebinding capk-manager-pods-read >/dev/null 2>&1 || true

# --- hosted cluster -----------------------------------------------------
log "removing HostedCluster ${HC_NAME}"
kdelete hostedcluster "$HC_NAME" -n "$CLUSTERS_NS" >/dev/null 2>&1 || true
if [[ "$DRY_RUN" != "1" ]]; then
  for _ in $(seq 1 60); do
    oc get hostedcluster "$HC_NAME" -n "$CLUSTERS_NS" >/dev/null 2>&1 || break
    sleep 10
  done
fi
rm -f "$HC_KUBECONFIG"

# --- operator -----------------------------------------------------------
if [[ "$ALL" == "1" ]]; then
  log "uninstalling the HyperShift operator"
  [[ -x "$HYPERSHIFT_BIN" ]] && "$HYPERSHIFT_BIN" install render --format=yaml 2>/dev/null \
    | oc delete --ignore-not-found -f - >/dev/null 2>&1 || true
  kdelete namespace hypershift --wait=false >/dev/null 2>&1 || true
  kdelete namespace "$CLUSTERS_NS" --wait=false >/dev/null 2>&1 || true
fi

ok "teardown complete"
