#!/usr/bin/env bash
# Step 4: build the CAPI scaffolding that HyperShift deliberately skips on
# platform=None, then render the node groups from nodetypes.yaml.
#
# HyperShift only creates a CAPI Cluster when a platform supplies an infra CR:
#
#   // In the None platform case, there is no CAPI provider/resources so infraCR is nil
#   if infraCR != nil { ... reconcileCAPICluster(...) }
#
# The CAPI *core manager* is still deployed, so once the Cluster object and the
# supporting secrets exist, the normal MachineDeployment -> MachineSet -> Machine
# flow works and HyperShift's own autoscaler can drive it.
#
# Four objects are needed beyond the node groups themselves:
#   <infraID>            CAPI Cluster (no infrastructureRef)
#   <infraID>-ca         cluster CA *with private key*, which CAPK uses to mint
#                        kubelet client certs (CN system:node:<name>)
#   kubemark-bootstrap   dummy bootstrap data to satisfy CAPI's bootstrap gate
#   hollow-pod-placement kubeconfig telling CAPK where to put hollow-node pods
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source ./env.sh
# shellcheck source=lib.sh
source ./lib.sh

need_cmd oc jq yq
need_cluster
mkdir -p "$GENERATED_DIR"

# --- 1. CAPI Cluster ----------------------------------------------------
# Named after infraID so that <infraID>-kubeconfig, which HyperShift already
# publishes, resolves by CAPI's own secret naming convention.
log "creating CAPI Cluster $INFRA_ID in $HCP_NS"
kapply <<EOF
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: ${INFRA_ID}
  namespace: ${HCP_NS}
  labels:
    sim-autoscale.io/managed: "true"
spec:
  # Point the control plane at HyperShift's own HostedControlPlane. Its CRD
  # carries the CAPI contract label (cluster.x-k8s.io/v1beta1: v1beta1) and it
  # reports status.ready/status.initialized, so it satisfies the control-plane
  # contract.
  #
  # Without this, CAPI falls back to looking for a Machine labelled
  # cluster.x-k8s.io/control-plane, finds none, and sets
  #   ControlPlaneInitialized=False "Waiting for the first control plane
  #   machine to have status.nodeRef set"
  # which cascades: Machine NodeHealthy/Ready go Unknown -> MachineDeployment
  # readyReplicas and availableReplicas stay 0 -> Cluster WorkersAvailable
  # False and phase Pending, even with every node Ready. Patching
  # status.initialization.controlPlaneInitialized does NOT help; CAPI
  # recomputes the condition.
  controlPlaneRef:
    apiGroup: hypershift.openshift.io
    kind: HostedControlPlane
    name: ${INFRA_ID}
  clusterNetwork:
    pods:
      cidrBlocks: ["10.132.0.0/14"]
    services:
      cidrBlocks: ["172.31.0.0/16"]
EOF

# With no infrastructureRef and no controlPlaneRef there is nothing to report
# provisioning, so CAPI will not mark the cluster initialized on its own and
# Machines would never be created. Force both contract fields.
if [[ "$DRY_RUN" != "1" ]]; then
  sleep 5
  prov="$(oc get cluster "$INFRA_ID" -n "$HCP_NS" \
            -o jsonpath='{.status.initialization.infrastructureProvisioned}' 2>/dev/null || true)"
  cpinit="$(oc get cluster "$INFRA_ID" -n "$HCP_NS" \
            -o jsonpath='{.status.initialization.controlPlaneInitialized}' 2>/dev/null || true)"
  if [[ "$prov" != "true" || "$cpinit" != "true" ]]; then
    log "patching Cluster status (infrastructureProvisioned=$prov controlPlaneInitialized=$cpinit)"
    oc patch cluster "$INFRA_ID" -n "$HCP_NS" --subresource=status --type=merge \
      -p '{"status":{"initialization":{"infrastructureProvisioned":true,"controlPlaneInitialized":true}}}'
  fi
  oc get cluster "$INFRA_ID" -n "$HCP_NS" \
    -o jsonpath='{.metadata.name}{"  provisioned="}{.status.initialization.infrastructureProvisioned}{"  cpInit="}{.status.initialization.controlPlaneInitialized}{"\n"}'
fi

# --- 2. cluster CA for CAPK --------------------------------------------
# CAPK reads secret <cluster>-ca with keys tls.crt/tls.key and signs a kubelet
# client certificate with it. HyperShift's cluster-signer-ca is part of the
# bundle the hosted kube-apiserver trusts for client auth (it is appended to
# both kubeletClientCABundle and totalClientCABundle), so certificates signed
# by it authenticate successfully. HyperShift stores it under ca.crt/ca.key,
# so the keys are remapped here.
if [[ "$DRY_RUN" == "1" ]]; then
  log "(dry-run) would copy cluster-signer-ca -> ${INFRA_ID}-ca"
else
  log "deriving ${INFRA_ID}-ca from cluster-signer-ca"
  oc get secret cluster-signer-ca -n "$HCP_NS" -o json \
    | jq --arg ns "$HCP_NS" --arg name "${INFRA_ID}-ca" '
        if (.data["ca.crt"] and .data["ca.key"]) then
          {apiVersion:"v1", kind:"Secret", type:"Opaque",
           metadata:{name:$name, namespace:$ns},
           data:{"tls.crt": .data["ca.crt"], "tls.key": .data["ca.key"]}}
        else
          error("cluster-signer-ca is missing ca.crt or ca.key")
        end' \
    | oc apply -f -
  ok "secret ${INFRA_ID}-ca ready"
fi

# --- 3. dummy bootstrap data -------------------------------------------
# CAPK never reads this; CAPI core just refuses to provision an infra machine
# until bootstrap data exists.
log "creating dummy bootstrap secret"
kapply <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kubemark-bootstrap
  namespace: ${HCP_NS}
type: cluster.x-k8s.io/secret
stringData:
  value: |
    #!/bin/sh
    # Intentionally empty: kubemark hollow nodes do not consume bootstrap data.
  format: cloud-config
EOF

# --- 4. hollow-pod placement -------------------------------------------
# Without this, CAPK creates hollow-node pods in the owner namespace -- the
# hosted control-plane namespace -- which would pollute any measurement of
# control-plane cost per node. Redirect them to a dedicated namespace using a
# kubeconfig for this same management cluster.
log "configuring hollow-pod placement into $HOLLOW_NS"
kapply <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${HOLLOW_NS}
---
# HyperShift's <infraID>-kubeconfig points at the UNQUALIFIED host
# "https://kube-apiserver:6443", which only resolves inside the control-plane
# namespace. Hollow pods run in ${HOLLOW_NS}, so without this alias every
# hollow kubelet fails with:
#   dial tcp: lookup kube-apiserver ... no such host
# and never registers a Node.
#
# An ExternalName alias fixes resolution while preserving the SNI hostname
# "kube-apiserver", which is a SAN on kas-server-private-crt -- so TLS still
# verifies. Rewriting the kubeconfig instead would be reverted by HyperShift.
apiVersion: v1
kind: Service
metadata:
  name: kube-apiserver
  namespace: ${HOLLOW_NS}
spec:
  type: ExternalName
  externalName: kube-apiserver.${HCP_NS}.svc.cluster.local
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hollow-placer
  namespace: ${HOLLOW_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hollow-placer
  namespace: ${HOLLOW_NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "delete", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hollow-placer
  namespace: ${HOLLOW_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: hollow-placer
subjects:
  - kind: ServiceAccount
    name: hollow-placer
    namespace: ${HOLLOW_NS}
---
apiVersion: v1
kind: Secret
metadata:
  name: hollow-placer-token
  namespace: ${HOLLOW_NS}
  annotations:
    kubernetes.io/service-account.name: hollow-placer
type: kubernetes.io/service-account-token
EOF

# Hollow nodes run with privileged: true, so both the namespace they land in
# and the control-plane namespace need the privileged SCC. Per-cluster,
# because HOLLOW_NS is derived from HC_NAME.
if [[ "$DRY_RUN" != "1" ]]; then
  for ns in "$HOLLOW_NS" "$HCP_NS"; do
    oc adm policy add-scc-to-user privileged "system:serviceaccount:${ns}:default" >/dev/null
    ok "granted privileged SCC to ${ns}:default"
  done
fi

if [[ "$DRY_RUN" != "1" ]]; then
  wait_for 120 "hollow-placer token populated" bash -c \
    "oc get secret hollow-placer-token -n '$HOLLOW_NS' -o jsonpath='{.data.token}' | grep -q ."

  SA_TOKEN="$(oc get secret hollow-placer-token -n "$HOLLOW_NS" -o jsonpath='{.data.token}' | base64 -d)"
  SA_CA_B64="$(oc get secret hollow-placer-token -n "$HOLLOW_NS" -o jsonpath='{.data.ca\.crt}')"

  # CAPK runs on this same cluster, so the in-cluster address is reachable and
  # avoids any dependency on external DNS.
  PLACEMENT_KUBECONFIG="$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: mgmt
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority-data: ${SA_CA_B64}
users:
  - name: hollow-placer
    user:
      token: ${SA_TOKEN}
contexts:
  - name: ctx
    context:
      cluster: mgmt
      user: hollow-placer
      namespace: ${HOLLOW_NS}
current-context: ctx
EOF
)"

  oc create secret generic hollow-pod-placement \
    -n "$HCP_NS" \
    --from-literal=kubeconfig="$PLACEMENT_KUBECONFIG" \
    --from-literal=namespace="$HOLLOW_NS" \
    --dry-run=client -o yaml | oc apply -f -
  ok "secret hollow-pod-placement ready (pods -> ${HOLLOW_NS})"
fi

# --- 5. node groups -----------------------------------------------------
NODETYPES_MANIFEST="$GENERATED_DIR/nodetypes-rendered.yaml"
./gen-nodetypes.sh > "$NODETYPES_MANIFEST"
log "rendered $(grep -c '^kind: MachineDeployment' "$NODETYPES_MANIFEST") node groups to $NODETYPES_MANIFEST"
kapply < "$NODETYPES_MANIFEST"

if [[ "$DRY_RUN" == "1" ]]; then
  ok "step 4 validated (dry-run)"
  exit 0
fi

echo
oc get machinedeployment -n "$HCP_NS" \
  -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,MIN:.metadata.annotations.cluster\.x-k8s\.io/cluster-api-autoscaler-node-group-min-size,MAX:.metadata.annotations.cluster\.x-k8s\.io/cluster-api-autoscaler-node-group-max-size'

ok "step 4 complete -- the autoscaler should now discover these node groups"
