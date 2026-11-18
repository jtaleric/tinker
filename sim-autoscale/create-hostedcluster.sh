#!/usr/bin/env bash
# Step 1: create the platform=None HostedCluster.
#
# No NodePool is created on purpose. A None-platform NodePool falls through to
# the default branch of machineTemplateBuilders() in the HyperShift operator
# and errors with "unsupported platform type: None". We drive MachineDeployments
# directly instead (see wire-capi.sh).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source ./env.sh
# shellcheck source=lib.sh
source ./lib.sh

need_cmd oc
need_cluster
resolve_release_image
mkdir -p "$GENERATED_DIR"

# --- namespace ----------------------------------------------------------
kapply <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CLUSTERS_NS}
EOF

# --- pull secret --------------------------------------------------------
# Reuse the management cluster's pull secret: it already carries credentials
# for registry.ci.openshift.org, which the CI release image requires.
if [[ "$DRY_RUN" == "1" ]]; then
  log "(dry-run) would copy pull-secret into ${CLUSTERS_NS}/${HC_NAME}-pull-secret"
else
  log "copying pull-secret into ${CLUSTERS_NS}/${HC_NAME}-pull-secret"
  oc get secret pull-secret -n openshift-config -o json \
    | jq --arg ns "$CLUSTERS_NS" --arg name "${HC_NAME}-pull-secret" \
        '{apiVersion:"v1", kind:"Secret", type:.type, data:.data,
          metadata:{name:$name, namespace:$ns}}' \
    | oc apply -f -
fi

# --- hosted cluster -----------------------------------------------------
HC_MANIFEST="$GENERATED_DIR/hostedcluster.yaml"
cat > "$HC_MANIFEST" <<EOF
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata:
  name: ${HC_NAME}
  namespace: ${CLUSTERS_NS}
spec:
  infraID: ${INFRA_ID}
  release:
    image: ${RELEASE_IMAGE}
  pullSecret:
    name: ${HC_NAME}-pull-secret
  platform:
    type: None
  dns:
    baseDomain: ${BASE_DOMAIN}
  networking:
    networkType: ${NETWORK_TYPE}
    clusterNetwork:
      - cidr: 10.132.0.0/14
    serviceNetwork:
      - cidr: 172.31.0.0/16
  controllerAvailabilityPolicy: SingleReplica
  infrastructureAvailabilityPolicy: SingleReplica
  etcd:
    managementType: Managed
    managed:
      storage:
        type: PersistentVolume
        persistentVolume:
          size: ${ETCD_STORAGE_SIZE}
          storageClassName: ${ETCD_STORAGE_CLASS}
  services:
    - service: APIServer
      servicePublishingStrategy:
        type: ${APISERVER_STRATEGY}
    - service: OAuthServer
      servicePublishingStrategy:
        type: Route
    - service: Konnectivity
      servicePublishingStrategy:
        type: Route
    - service: Ignition
      servicePublishingStrategy:
        type: Route
EOF
log "rendered $HC_MANIFEST"

# --- autoscaler enabler NodePool (manifest) ----------------------------
# Rendered here, alongside the HostedCluster, so dry-run and offline schema
# validation cover it too. It is applied further down, after the control plane
# is Available. See the long note at the apply site for why it exists.
NP_MANIFEST="$GENERATED_DIR/nodepool-autoscaler-enabler.yaml"
cat > "$NP_MANIFEST" <<EOF
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: ${HC_NAME}-autoscaler-enabler
  namespace: ${CLUSTERS_NS}
spec:
  clusterName: ${HC_NAME}
  release:
    image: ${RELEASE_IMAGE}
  platform:
    type: None
  management:
    upgradeType: InPlace
  autoScaling:
    min: 1
    max: 1
EOF
log "rendered $NP_MANIFEST"

kapply < "$HC_MANIFEST"

if [[ "$DRY_RUN" == "1" ]]; then
  # Render the NodePool too so schema validation sees it. It cannot be
  # server-dry-run before the HostedCluster exists, so print only.
  RENDER=1 kapply < "$NP_MANIFEST"
  ok "step 1 validated (dry-run)"
  exit 0
fi

# --- wait ---------------------------------------------------------------
# The control plane takes a while to roll out; the hosted CVO will never reach
# Completed because there are no nodes, so Available is the signal we use.
wait_for 1800 "HostedCluster ${HC_NAME} Available" \
  oc wait --for=condition=Available --timeout=10s \
    "hostedcluster/${HC_NAME}" -n "$CLUSTERS_NS"

# --- autoscaler enabler NodePool ---------------------------------------
# Without this the cluster-autoscaler deployment is created but scaled to ZERO.
#
# The HyperShift operator computes isAutoscalingNeeded() by listing NodePools
# and checking whether any has spec.autoScaling set. With no NodePool it stamps
# hypershift.openshift.io/disable-cluster-autoscaler=true onto the
# HostedControlPlane, and the autoscaler's adaptDeployment() then sets
# replicas=0. That check is on annotation *existence*, not value, so setting it
# to "false" does not help, and the operator reverts manual edits. Creating a
# NodePool with autoScaling is the only lever.
#
# This NodePool intentionally provisions nothing: None-platform NodePools have
# no CAPI machine template (machineTemplateBuilders hits its default branch),
# so no MachineDeployment is created and no Machine is ever requested. It
# settles at AllMachinesReady=False / "No Machines are created", which is
# expected and does not affect HostedCluster availability. The node groups we
# actually scale are the MachineDeployments created in wire-capi.sh.
log "creating autoscaler-enabler NodePool (makes HyperShift run the autoscaler)"
kapply < "$NP_MANIFEST"

wait_for 300 "cluster-autoscaler scaled up by HyperShift" bash -c \
  "[[ \"\$(oc get deploy cluster-autoscaler -n '$HCP_NS' -o jsonpath='{.spec.replicas}' 2>/dev/null)\" == '1' ]]"

# --- admin kubeconfig ---------------------------------------------------
wait_for 300 "admin kubeconfig secret published" \
  oc get "secret/${HC_NAME}-admin-kubeconfig" -n "$CLUSTERS_NS"

oc get "secret/${HC_NAME}-admin-kubeconfig" -n "$CLUSTERS_NS" \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > "$HC_KUBECONFIG"
chmod 600 "$HC_KUBECONFIG"
ok "hosted cluster kubeconfig written to $HC_KUBECONFIG"

log "control plane namespace: $HCP_NS"
oc get pods -n "$HCP_NS" --no-headers 2>/dev/null | awk '{print $1, $3}' | head -20 || true

ok "step 1 complete"
