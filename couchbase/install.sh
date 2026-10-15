#!/bin/bash
set -e

# --- Configuration Variables ---
NAMESPACE="couchbase-cudn"
CB_USER="Administrator"
CB_PASS="Password123!"
SSH_PASS="couchbase"
SSH_USER="cloud-user"
ADDRESS="10.30.0.0/24"
SSH_ARGS="-o StrictHostKeyChecking=no"
IS_CUDN=true

cleanup_cudn() {
    local ns="${1:-${NAMESPACE}}"

    if [[ -z "$ns" ]]; then
        echo "Error: Namespace is required. Usage: cleanup_cudn <namespace> or set \$NAMESPACE" >&2
        return 1
    fi
    echo "=== Cleaning up CUDN, RouteAdvertisements, and Namespace: ${ns} ==="
    echo "Deleting RouteAdvertisements 'couchbase-cudn-ra'..."
    oc delete routeadvertisements couchbase-cudn-ra -n "${ns}" --ignore-not-found
    echo "Deleting Namespace '${ns}'..."
    oc delete namespace "${ns}" --ignore-not-found
    echo "Deleting ClusterUserDefinedNetwork '${ns}'..."
    oc delete clusteruserdefinednetwork "${ns}" --ignore-not-found
    echo "=== Cleanup completed ==="
}

if $IS_CUDN; then
cleanup_cudn
else
echo "Deleting Namespace '${ns}'..."
oc delete namespace "${ns}" --ignore-not-found
fi

if $IS_CUDN; then
echo "=== 0. Create CUDN  and RA==="
cat << EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${NAMESPACE} 
  labels:
    app: ${NAMESPACE}
spec:
  network:
    topology: Layer2
    layer2:
      role: Primary
      ipam:
        lifecycle: Persistent
      subnets:
        - "${ADDRESS}" 
  namespaceSelector:
    matchLabels:
      k8s.ovn.org/user-defined-network: "${NAMESPACE}"
EOF

cat << EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: ${NAMESPACE} 
  namespace: ${NAMESPACE} 
spec:
  nodeSelector: {}
  frrConfigurationSelector: {}
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            app: "${NAMESPACE}" 
  advertisements:
    - "PodNetwork"
EOF

echo "=== 1. Creating namespace with CUDN selection label ==="
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    k8s.ovn.org/user-defined-network: "${NAMESPACE}"
    k8s.ovn.org/primary-user-defined-network: ""
EOF
else
echo "=== 1. Creating namespace with CUDN selection label ==="
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF

fi

echo "=== 2. Creating Headless Service for internal cluster discovery ==="
cat <<EOF | oc apply -n ${NAMESPACE} -f -
apiVersion: v1
kind: Service
metadata:
  name: cb-cluster
spec:
  clusterIP: None
  selector:
    app: couchbase
  ports:
    - port: 8091
      name: rest
    - port: 18091
      name: rest-ssl
EOF

echo "=== 3. Deploying 12 Couchbase VMs with 0.0.0.0 Binding on CUDN ==="
for i in {1..12}; do
  VM_NAME="couchbase-node-${i}"
  echo "Deploying ${VM_NAME}..."
  
  cat <<EOF | oc apply -n ${NAMESPACE} -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM_NAME}
        app: couchbase
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - couchbase
            topologyKey: kubernetes.io/hostname
      domain:
        cpu:
          cores: 12
        resources:
          requests:
            memory: 64G
        devices:
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            bridge: {}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/centos-stream:9
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: cloud-user
            password: ${SSH_PASS}
            chpasswd: { expire: False }
            ssh_pwauth: True
            runcmd:
              - echo never > /sys/kernel/mm/transparent_hugepage/enabled
              - echo never > /sys/kernel/mm/transparent_hugepage/defrag
              - sysctl vm.swappiness=0
              
              # Direct RPM install
              - curl -O https://packages.couchbase.com/releases/7.6.2/couchbase-server-enterprise-7.6.2-linux.x86_64.rpm
              - sudo dnf install -y ./couchbase-server-enterprise-7.6.2-linux.x86_64.rpm
              
              # FORCE COUCHBASE TO BIND TO ALL INTERFACES (0.0.0.0)
              - echo '{ip_address, "0.0.0.0"}.' >> /opt/couchbase/etc/couchbase/static_config
              
              - sudo systemctl enable --now couchbase-server
EOF
done

echo "Waiting 300 seconds for VMs to boot and Couchbase services to initialize..."
sleep 300 

if $IS_CUDN; then
set -x
# Standard SSH options for automation (disable host checking & pass options)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

echo "=== 1. Discovering CUDN IPs for all Nodes ==="
# Helper function to get CUDN IP from VMI status or guest agent
get_cudn_ip() {
  local node_idx=$1
  oc get vmi "couchbase-node-${node_idx}" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null
}

NODE1_IP=$(get_cudn_ip 1)
if [[ -z "${NODE1_IP}" ]]; then
  echo "ERROR: Could not resolve CUDN IP for couchbase-node-1"
  exit 1
fi
echo "Node 1 CUDN IP: ${NODE1_IP}"

echo "=== 4. Initializing Node 1 Seed Cluster (with Retry Loop) ==="
MAX_RETRIES=10
RETRY_DELAY=10
ATTEMPT=1
INIT_SUCCESS=0

while [ ${ATTEMPT} -le ${MAX_RETRIES} ]; do
  echo "Attempt ${ATTEMPT} of ${MAX_RETRIES}: Initializing cluster on couchbase-node-1 (${NODE1_IP})..."

  if sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} \
    "sudo /opt/couchbase/bin/couchbase-cli cluster-init -c 127.0.0.1:8091 --cluster-username '${CB_USER}' --cluster-password '${CB_PASS}' --cluster-ramsize 50000 --cluster-index-ramsize 50000 --services data"; then
    
    echo "Node 1 cluster-init succeeded!"
    INIT_SUCCESS=1
    break
  else
    echo "Couchbase on Node 1 is not ready yet. Waiting ${RETRY_DELAY} seconds..."
    sleep ${RETRY_DELAY}
    ATTEMPT=$((ATTEMPT + 1))
  fi
done

if [ ${INIT_SUCCESS} -ne 1 ]; then
  echo "ERROR: Failed to initialize cluster on Node 1 after ${MAX_RETRIES} attempts."
  exit 1
fi

echo "=== 7. Registering Nodes 2-12 to Node 1 via CUDN IPs ==="
for i in {2..12}; do
  if [ "${i}" -le 6 ]; then
    SERVICES="data"
  elif [ "${i}" -le 9 ]; then
    SERVICES="index"
  else
    SERVICES="query"
  fi

  # Fetch target node CUDN IP directly from KubeVirt VMI metadata
  CUDN_IP=$(get_cudn_ip ${i})
  
  # Fallback: Query guest OS directly if VMI metadata doesn't report interface IP yet
  if [[ -z "${CUDN_IP}" ]]; then
    echo "Warning: VMI IP lookup failed for couchbase-node-${i}, querying guest interface directly..."
    CUDN_IP=$(sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} ${SSH_USER}@couchbase-node-${i} \
      "ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" 2>/dev/null | tr -d '\r\n')
  fi

  echo "Adding couchbase-node-${i} (CUDN IP: ${CUDN_IP}) with services: ${SERVICES}..."

  sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} \
    "sudo /opt/couchbase/bin/couchbase-cli server-add -c 127.0.0.1:8091 -u '${CB_USER}' -p '${CB_PASS}' --server-add https://${CUDN_IP}:18091 --server-add-username '${CB_USER}' --server-add-password '${CB_PASS}' --services '${SERVICES}' --no-ssl-verify"
done

echo "=== 8. Triggering Cluster Rebalance ==="
sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} \
  "sudo /opt/couchbase/bin/couchbase-cli rebalance -c 127.0.0.1:8091 -u '${CB_USER}' -p '${CB_PASS}'"

echo "=== Deployment Complete ==="
echo "Verifying server list:"
sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} \
  "sudo /opt/couchbase/bin/couchbase-cli server-list -c 127.0.0.1:8091 -u '${CB_USER}' -p '${CB_PASS}'"
fi
if ! $IS_CUDN; then
echo "=== 4. Initializing Node 1 Seed Cluster (with Retry Loop) ==="
MAX_RETRIES=10
RETRY_DELAY=10
ATTEMPT=1
INIT_SUCCESS=0

while [ ${ATTEMPT} -le ${MAX_RETRIES} ]; do
  echo "Attempt ${ATTEMPT} of ${MAX_RETRIES}: Initializing cluster on couchbase-node-1..."

echo "=== 6. Initializing Node 1 Seed Cluster ==="
sshpass -p "${SSH_PASS}" virtctl ssh cloud-user@vmi/couchbase-node-1 -n ${NAMESPACE} \
  -t "${SSH_ARGS}" \
  --command "sudo /opt/couchbase/bin/couchbase-cli cluster-init -c 127.0.0.1:8091 --cluster-username '${CB_USER}' --cluster-password '${CB_PASS}' --cluster-ramsize 50000 --cluster-index-ramsize 50000 --services data"
if [[ $? -eq 0 ]]; then
    echo "Node 1 cluster-init succeeded!"
    INIT_SUCCESS=1
    break
  else
    echo "Couchbase on Node 1 is not ready yet. Waiting ${RETRY_DELAY} seconds..."
    sleep ${RETRY_DELAY}
    ATTEMPT=$((ATTEMPT + 1))
  fi

done

echo "=== 7. Registering Nodes 2-12 to Node 1 via CUDN IPs ==="
for i in {2..12}; do
  if [ "${i}" -le 6 ]; then
    SERVICES="data"
  elif [ "${i}" -le 9 ]; then
    SERVICES="index"
  else
    SERVICES="query"
  fi


  # Query the actual CUDN eth0 IP directly from inside the VM guest
  CUDN_IP=$(sshpass -p "${SSH_PASS}" virtctl ssh cloud-user@vmi/couchbase-node-${i} -n ${NAMESPACE} \
    -t "${SSH_ARGS}" \
    --command "ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" 2>/dev/null | tr -d '\r\n')

  echo "Adding couchbase-node-${i} (CUDN IP: ${CUDN_IP}) with services: ${SERVICES}..."

  sshpass -p "${SSH_PASS}" virtctl ssh cloud-user@vmi/couchbase-node-1 -n ${NAMESPACE} \
    -t "${SSH_ARGS}" \
    --command "sudo /opt/couchbase/bin/couchbase-cli server-add -c 127.0.0.1:8091 -u '${CB_USER}' -p '${CB_PASS}' --server-add https://'${CUDN_IP}':18091 --server-add-username '${CB_USER}' --server-add-password '${CB_PASS}' --services '${SERVICES}' --no-ssl-verify"
done

echo "=== 8. Triggering Cluster Rebalance ==="
sshpass -p "${SSH_PASS}" virtctl ssh cloud-user@vmi/couchbase-node-1 -n ${NAMESPACE} \
  -t "${SSH_ARGS}" \
  --command "sudo /opt/couchbase/bin/couchbase-cli rebalance -c 127.0.0.1:8091 -u '${CB_USER}' -p '${CB_PASS}'"

echo "=== Deployment Complete ==="
echo "Verifying server list:"
sshpass -p "${SSH_PASS}" virtctl ssh cloud-user@vmi/couchbase-node-1 -n ${NAMESPACE} \
  -t "${SSH_ARGS}" \
  --command "sudo /opt/couchbase/bin/couchbase-cli server-list -c 127.0.0.1:8091 -u '${CB_USER}' -p '${CB_PASS}'"
fi
