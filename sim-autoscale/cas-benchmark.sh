#!/usr/bin/env bash
# cas-benchmark -- exercise and measure HyperShift's cluster-autoscaler.
#
# WORKLOADS
#   basic      <cluster>                     scale up, then down. Sanity check.
#   baseline   <cluster> <nodes> [groups]    pin a stable starting population
#   breakpoint <cluster> [mult...]           ramp up+down until something fails
#
# OPERATIONS
#   status     [cluster]                     fleet inventory, or one cluster's detail
#   measure    <cluster>                     autoscaler loop timings
#   groups     <cluster> <count>             set the number of node groups
#   tune       <cluster> [qps] [burst] [s]   raise client QPS, shorten scale-down
#   reset      [--hard]                      wipe machines fleet-wide, keep clusters
#
# WHAT STRESSES THE AUTOSCALER
# Its cost grows on three independent axes, and every loop re-evaluates all of
# them: node-group count (cloudProviderRefresh + scale-up simulation per
# group), node count (findUnneeded checks every node), and pending-pod count
# (filterOutSchedulable simulates each pod). The headline number is
# function_duration{function="main"} -- one full loop. Once that exceeds the
# 10s scan interval the autoscaler is permanently behind and acting on stale
# state.
#
# Metrics come straight from each autoscaler pod on :8085. HyperShift ships a
# PodMonitor but platform Prometheus does not scrape hosted control-plane
# namespaces, so Prometheus has none of these.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source ./env.sh
# shellcheck source=lib.sh
source ./lib.sh

need_cmd oc python3 jq
need_cluster

RESULTS="${CAS_RESULTS:-$SIM_ROOT/results/cas}"
SETTLE="${SETTLE:-180}"
POD_CPU="${POD_CPU:-2}"
CPU_PER_NODE="${CPU_PER_NODE:-8}"
# Must exceed one autoscaler loop or nothing is measured; loops of 30-170s
# have been observed, so 60 silently produces empty rows.
WINDOW="${WINDOW:-240}"
CHURN="${CHURN:-1}"
CHURN_FLOOR_PCT="${CHURN_FLOOR_PCT:-10}"
mkdir -p "$RESULTS"

cmd="${1:-status}"
cluster="${2:-}"
ns=""; kc=""
if [[ -n "$cluster" ]]; then
  ns="clusters-${cluster}"
  kc="$SIM_ROOT/${cluster}-admin.kubeconfig"
  # Fetch the admin kubeconfig if we do not have it -- lets this work against
  # clusters that were not created by these scripts.
  if [[ ! -s "$kc" ]] && oc get hostedcluster "$cluster" -n "$CLUSTERS_NS" >/dev/null 2>&1; then
    oc get "secret/${cluster}-admin-kubeconfig" -n "$CLUSTERS_NS" \
      -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > "$kc" 2>/dev/null || true
    [[ -s "$kc" ]] && chmod 600 "$kc" || rm -f "$kc"
  fi
fi

need_cluster_arg() { [[ -n "$cluster" ]] || die "usage: $0 $cmd <cluster> [...]"; }

# ---------------------------------------------------------------- helpers ---
nodes_now()    { [[ -s "$kc" ]] && oc --kubeconfig "$kc" get nodes --no-headers 2>/dev/null | wc -l || echo 0; }
machines_now() { oc get machines -n "$ns" --no-headers 2>/dev/null | wc -l; }
# Count pending ONLY in the driver namespace. The hosted cluster has its own
# permanently-pending pods (one openshift-ingress-canary per node, never
# schedulable on kubemark), so a cluster-wide count grows with node count and
# makes every threshold meaningless.
pending_now()  { [[ -s "$kc" ]] && oc --kubeconfig "$kc" get pods -n "$DRIVER_NS" \
                   --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo 0; }
restarts_now() { oc get pods -n "$ns" -l app=cluster-autoscaler \
                   -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0; }

# Spare capacity across all node groups. Distinguishes "autoscaler is stuck"
# from "autoscaler correctly declined because every group is at max".
headroom_now() {
  oc get machinedeployment -n "$ns" -o json 2>/dev/null | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
rep=sum(i["spec"].get("replicas",0) or 0 for i in d.get("items",[]))
mx=sum(int(i["metadata"].get("annotations",{}).get(
    "cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size",0) or 0) for i in d.get("items",[]))
print(mx-rep)' 2>/dev/null || echo 0
}

scrape() {
  local p; p="$(oc get pods -n "$ns" -l app=cluster-autoscaler -o name 2>/dev/null | head -1)"
  [[ -n "$p" ]] || return 1
  oc exec -n "$ns" "$p" -- curl -s localhost:8085/metrics 2>/dev/null
}

# Two scrapes WINDOW apart. function_duration is cumulative, so a single
# scrape yields the mean over the autoscaler's whole life (36s/loop lifetime
# vs ~0.4s actual, measured) -- useless for current behaviour.
measure() { # [csv] [phase] [elapsed]
  local a b
  a="$(mktemp)"; b="$(mktemp)"
  scrape > "$a" 2>/dev/null || { rm -f "$a" "$b"; return 1; }
  sleep "$WINDOW"
  scrape > "$b" 2>/dev/null || { rm -f "$a" "$b"; return 1; }
  python3 -I ./autoscaler-metrics.py "$a" "$b" "$@"
  rm -f "$a" "$b"
}

# Pending-pod pressure in the hosted cluster: what the autoscaler simulates
# against every node group on every loop.
set_pods() { # <count>
  local n="$1"
  [[ -s "$kc" ]] || die "no kubeconfig for $cluster"
  oc --kubeconfig "$kc" create namespace "$DRIVER_NS" --dry-run=client -o yaml 2>/dev/null \
    | oc --kubeconfig "$kc" apply -f - >/dev/null 2>&1 || true
  oc --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: scale-driver, namespace: ${DRIVER_NS}}
spec:
  replicas: ${n}
  selector: {matchLabels: {app: scale-driver}}
  template:
    metadata: {labels: {app: scale-driver}}
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources: {requests: {cpu: "${POD_CPU}", memory: 1Gi}}
EOF
  log "$cluster: driving $n pods at ${POD_CPU} cpu each"
}

set_groups() { # <count> -- regenerates node groups; replicas are preserved
  local want="$1" have rendered err target
  have="$(oc get machinedeployment -n "$ns" --no-headers 2>/dev/null | wc -l)"
  log "$cluster: node groups $have -> $want"
  rendered="$(mktemp)"; err="$(mktemp)"
  if ! NODETYPE_COUNT="$want" CLUSTER_PROFILE="$cluster" ./gen-nodetypes.sh > "$rendered" 2>"$err"; then
    err "failed to render $want node groups:"; sed 's/^/    /' "$err" >&2
    rm -f "$rendered" "$err"; return 1
  fi
  # Guard against derived-variable leakage across profiles: verify the
  # manifests target THIS cluster before applying them.
  target="$(grep -m1 '^  namespace:' "$rendered" | awk '{print $2}')"
  if [[ "$target" != "$ns" ]]; then
    err "rendered manifests target '$target', expected '$ns' -- refusing"
    rm -f "$rendered" "$err"; return 1
  fi
  oc apply -f "$rendered" >/dev/null 2>&1 || warn "some node groups failed to apply"
  rm -f "$rendered" "$err"
  if (( want < have )); then
    for md in $(oc get machinedeployment -n "$ns" -o name 2>/dev/null | tail -n +"$(( want + 1 ))"); do
      force_delete 60 machinedeployment "${md##*/}" -n "$ns"
    done
  fi
  ok "$cluster: $(oc get machinedeployment -n "$ns" --no-headers 2>/dev/null | wc -l) node groups"
}

# Objective failure conditions. Sets BROKE / CEILING.
check_state() { # <label> <nodes-before> <csv>
  local label="$1" before="$2" csv="$3"
  local after pend restarts head loops main
  after="$(nodes_now)"; pend="$(pending_now)"; restarts="$(restarts_now)"; head="$(headroom_now)"
  loops="$(tail -1 "$csv" 2>/dev/null | cut -d, -f10)"
  main="$(tail -1 "$csv" 2>/dev/null | cut -d, -f11)"
  printf '  [%s] nodes %s -> %s  pending=%s  headroom=%s  loops=%s  main=%sms  restarts=%s\n' \
    "$label" "$before" "$after" "$pend" "$head" "${loops:-?}" "${main:-?}" "$restarts"

  BROKE=""; CEILING=""
  [[ "${loops:-0}" == "0" ]] && BROKE="autoscaler completed NO loops in the window"
  (( restarts > BASE_RESTARTS )) && BROKE="autoscaler restarted ($BASE_RESTARTS -> $restarts)"
  if [[ -z "$BROKE" ]] && (( after <= before && pend > 10 )); then
    if (( head <= 0 )); then
      CEILING="all node groups at max ($pend pods pending, headroom=0)"
    else
      BROKE="$pend pods pending, $head headroom free, but nodes did not grow"
    fi
  fi
  # Exceeding the scan interval means stale decisions, NOT failure -- the
  # autoscaler still scales. Warn, do not stop.
  if [[ -z "$BROKE" && -n "${main:-}" ]] \
     && python3 -I -c "import sys; sys.exit(0 if float('${main:-0}') > 10000 else 1)"; then
    warn "  over budget: loop ${main}ms > 10000ms interval (stale decisions, still scaling)"
  fi
}

# ------------------------------------------------------------------- main ---
case "$cmd" in

status)
  if [[ -z "$cluster" ]]; then
    printf '%-10s %-10s %-18s %-9s %-7s %-9s %s\n' NAME VERSION CAPI CONVERTS GROUPS MACHINES NODES
    while IFS=$'\t' read -r hcns name; do
      [[ -n "$name" ]] || continue
      local_ns="clusters-${name}"; local_kc="$SIM_ROOT/${name}-admin.kubeconfig"
      ver="$(oc get hostedcluster "$name" -n "$hcns" -o jsonpath='{.status.version.desired.version}' 2>/dev/null)"
      # If v1beta1 appears AT ALL the client converts. Taking the last
      # sorted match picks v1beta2 and reports the opposite of the truth.
      capi_raw="$(oc logs deploy/cluster-api -n "$local_ns" --tail=300 2>/dev/null \
                   | grep -oE 'v1beta[12]' | sort -u | tr '\n' '+' | sed 's/+$//')"
      conv=no; [[ "$capi_raw" == *v1beta1* ]] && conv=YES
      capi="${capi_raw:-?}"
      nds=0; [[ -s "$local_kc" ]] && nds="$(oc --kubeconfig "$local_kc" get nodes --no-headers 2>/dev/null | wc -l)"
      printf '%-10s %-10s %-18s %-9s %-7s %-9s %s\n' "$name" "${ver:-?}" "${capi:-?}" "$conv" \
        "$(oc get machinedeployment -n "$local_ns" --no-headers 2>/dev/null | wc -l)" \
        "$(oc get machines -n "$local_ns" --no-headers 2>/dev/null | wc -l)" "$nds"
    done < <(oc get hostedcluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    echo
    warn "CONVERTS=no means v1beta2-native CAPI: that cluster generates no conversion load."
  else
    printf '  cluster   : %s\n' "$cluster"
    printf '  groups    : %s   machines: %s   nodes: %s\n' \
      "$(oc get machinedeployment -n "$ns" --no-headers 2>/dev/null | wc -l)" "$(machines_now)" "$(nodes_now)"
    printf '  headroom  : %s   driver pods pending: %s\n' "$(headroom_now)" "$(pending_now)"
    printf '  autoscaler: %s\n' "$(oc get pods -n "$ns" -l app=cluster-autoscaler --no-headers 2>/dev/null | head -1)"
    echo "  node groups:"
    oc get machinedeployment -n "$ns" -o custom-columns='  NAME:.metadata.name,REPLICAS:.spec.replicas,MIN:.metadata.annotations.cluster\.x-k8s\.io/cluster-api-autoscaler-node-group-min-size,MAX:.metadata.annotations.cluster\.x-k8s\.io/cluster-api-autoscaler-node-group-max-size' --no-headers 2>/dev/null | sed 's/^/  /'
  fi
  ;;

measure)
  need_cluster_arg
  log "sampling over ${WINDOW}s (cumulative metrics need two scrapes)"
  measure || die "could not scrape the autoscaler in $ns"
  ;;

groups)
  need_cluster_arg
  set_groups "${3:?usage: $0 groups <cluster> <count>}"
  ;;

tune)
  need_cluster_arg
  # Both are supported HostedCluster API fields.
  #   kubeClientQPS/Burst  unset by default -> client-go defaults of 5 QPS,
  #                        so the rate limiter dominates loop time.
  #   scaleDown.*          defaults are 10m unneeded + 10m delayAfterAdd,
  #                        making one churn cycle ~25 minutes.
  qps="${3:-200}"; burst="${4:-300}"; unneeded="${5:-60}"
  log "$cluster: qps=$qps burst=$burst scaleDown.unneeded=${unneeded}s"
  oc patch hostedcluster "$cluster" -n "$CLUSTERS_NS" --type=merge -p "{
    \"spec\":{\"autoscaling\":{
      \"kubeClientQPS\":$qps,\"kubeClientBurst\":$burst,
      \"scaleDown\":{\"unneededDurationSeconds\":$unneeded,\"delayAfterAddSeconds\":$unneeded,
                     \"delayAfterDeleteSeconds\":10,\"delayAfterFailureSeconds\":30}}}}" >/dev/null \
    || die "patch failed"
  sleep 45
  if oc get deploy cluster-autoscaler -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
       | grep -q "kube-client-qps"; then
    ok "qps args reached the deployment"
  else
    warn "scaleDown args apply, but --kube-client-qps did NOT appear."
    warn "HyperShift only REPLACES an existing --kube-client-qps= arg; it never"
    warn "appends one. If this hosted cluster's control-plane-operator (which"
    warn "comes from ITS release payload, not the management cluster) predates"
    warn "that arg, the API field is silently inert. Seen on 4.19/4.20."
  fi
  ;;

reset)
  # Start fresh without rebuilding hosted clusters. Order matters:
  #  1. cap max-size at 0 FIRST. Each hosted cluster's own system pods
  #     (mtu-prober, network-operator, ...) trigger scale-up the instant a
  #     group reaches 0, so deleting alone never converges.
  #  2. remove driver workloads.
  #  3. scale groups to 0 -- never `oc delete machine` on MachineSet-owned
  #     machines; the MachineSet just recreates them.
  #  4. delete orphans explicitly (synthesized machines have no owner).
  #  5. force-strip CAPI finalizers rather than hanging forever.
  hard=0; [[ "${2:-}" == "--hard" ]] && hard=1
  mapfile -t fleet < <(oc get hostedcluster -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  (( ${#fleet[@]} > 0 )) || die "no HostedClusters found"

  for row in "${fleet[@]}"; do
    IFS=$'\t' read -r hcns name <<<"$row"
    rns="clusters-${name}"; rkc="$SIM_ROOT/${name}-admin.kubeconfig"
    log "$name: capping groups at max=0 and scaling to 0"
    for md in $(oc get machinedeployment -n "$rns" -o name 2>/dev/null); do
      oc annotate -n "$rns" "$md" --overwrite \
        'cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size=0' >/dev/null 2>&1 || true
      oc scale -n "$rns" "$md" --replicas=0 >/dev/null 2>&1 || true
    done
    [[ -s "$rkc" ]] && oc --kubeconfig "$rkc" -n "$DRIVER_NS" \
      scale deploy/scale-driver --replicas=0 >/dev/null 2>&1 || true
    oc delete machine -n "$rns" -l sim-autoscale.io/synth=true --wait=false >/dev/null 2>&1 || true
    oc delete awsmachine -n "$rns" -l sim-autoscale.io/synth=true --wait=false >/dev/null 2>&1 || true
  done

  log "waiting for machines to drain"
  deadline=$(( SECONDS + 600 ))
  while (( SECONDS < deadline )); do
    total=0
    for row in "${fleet[@]}"; do
      IFS=$'\t' read -r hcns name <<<"$row"
      total=$(( total + $(oc get machines -n "clusters-${name}" --no-headers 2>/dev/null | wc -l) ))
    done
    (( total == 0 )) && break
    log "  $total machines remaining..."
    sleep 15
  done

  for row in "${fleet[@]}"; do
    IFS=$'\t' read -r hcns name <<<"$row"
    rns="clusters-${name}"
    for m in $(oc get machines -n "$rns" -o name 2>/dev/null | cut -d/ -f2); do
      warn "$name: force-removing stuck machine $m"; force_delete 30 machine "$m" -n "$rns"
    done
    if (( hard )); then
      for md in $(oc get machinedeployment -n "$rns" -o name 2>/dev/null | cut -d/ -f2); do
        force_delete 60 machinedeployment "$md" -n "$rns"
      done
      oc delete kubemarkmachinetemplate --all -n "$rns" --wait=false >/dev/null 2>&1 || true
    fi
    printf '  %-10s machines=%-4s groups=%s\n' "$name" \
      "$(oc get machines -n "$rns" --no-headers 2>/dev/null | wc -l)" \
      "$(oc get machinedeployment -n "$rns" --no-headers 2>/dev/null | wc -l)"
  done
  if (( hard )); then
    ok "reset --hard complete -- node groups removed; re-run ./wire-capi.sh"
  else
    ok "reset complete -- groups are CAPPED AT max=0 so the baseline holds"
    warn "restore before testing:  CLUSTER_PROFILE=<c> ./wire-capi.sh"
    warn "                    or:  $0 groups <cluster> <n>"
  fi
  ;;

baseline)
  need_cluster_arg
  # Pin a stable starting population. Do NOT pre-scale replicas alone: the
  # autoscaler treats idle nodes as unneeded and removes them mid-test.
  # Setting min-size makes it a floor it will not cross. Note the autoscaler
  # does NOT scale UP to satisfy min -- min only blocks scale-DOWN -- so
  # gen-nodetypes.sh also clamps replicas up to min.
  total="${3:?usage: $0 baseline <cluster> <nodes> [groups]}"
  grps="${4:-4}"
  per=$(( (total + grps - 1) / grps ))
  log "$cluster: baseline $total nodes across $grps groups (min=$per each)"
  NODEGROUP_MIN_OVERRIDE="$per" set_groups "$grps" || die "could not create node groups"

  log "waiting for $total machines"
  deadline=$(( SECONDS + 900 )); last=-1
  while (( SECONDS < deadline )); do
    have="$(machines_now)"; (( have >= total )) && break
    (( have != last )) && log "  $have/$total machines"
    last="$have"; sleep 15
  done
  have="$(machines_now)"
  if (( have >= total )); then
    ok "$cluster: baseline reached -- $have machines, $(nodes_now) nodes"
  else
    warn "$cluster: only $have/$total machines after 15m -- check: $0 measure $cluster"
  fi
  warn "min-size is $per per group. Clear it before a scale-from-zero test:"
  warn "  NODEGROUP_MIN_OVERRIDE=0 $0 groups $cluster $grps"
  ;;

basic)
  need_cluster_arg
  # Sanity check: does this cluster scale UP and back DOWN at all?
  BASE_RESTARTS="$(restarts_now)"
  CSV="$RESULTS/basic-${cluster}-$(date -u +%Y%m%d-%H%M%S).csv"
  start_nodes="$(nodes_now)"
  want=$(( start_nodes + 5 ))
  pods=$(( want * CPU_PER_NODE / POD_CPU ))

  log "UP: $start_nodes -> ~$want nodes ($pods pods)"
  set_pods "$pods"; sleep "$SETTLE"
  measure "$CSV" up 0 || warn "scrape failed"
  check_state up "$start_nodes" "$CSV"
  [[ -n "$CEILING" ]] && warn "at ceiling: $CEILING"
  [[ -n "$BROKE" ]] && err "scale-up problem: $BROKE"

  peak="$(nodes_now)"
  log "DOWN: collapse to 0 pods and wait for scale-down"
  set_pods 0; sleep "$SETTLE"
  measure "$CSV" down "$SETTLE" || warn "scrape failed"
  check_state down "$peak" "$CSV"
  after="$(nodes_now)"
  if (( after < peak )); then
    ok "scaled down $peak -> $after"
  else
    warn "no scale-down ($peak -> $after). CA defaults to 10m unneeded; run: $0 tune $cluster"
  fi
  ok "results: $CSV"
  ;;

breakpoint)
  need_cluster_arg
  # Ramp demand UP and back DOWN at each step so scale-down is exercised too.
  # Demand is RELATIVE and compounding: a fixed pod count proves nothing when
  # you do not control the starting size (12 pods on a 35-node cluster
  # schedules instantly and measures nothing).
  shift 2
  steps=("${@:-}")
  [[ -z "${steps[0]:-}" ]] && steps=(1 2 4 8 16)
  BASE_RESTARTS="$(restarts_now)"
  CSV="$RESULTS/breakpoint-${cluster}-$(date -u +%Y%m%d-%H%M%S).csv"
  T0=$SECONDS
  log "$cluster: from $(nodes_now) nodes; multipliers: ${steps[*]}; churn=$CHURN (floor ${CHURN_FLOOR_PCT}%)"

  for mult in "${steps[@]}"; do
    now_nodes="$(nodes_now)"
    want=$(( (now_nodes + 1) * mult ))
    pods=$(( want * CPU_PER_NODE / POD_CPU ))
    echo
    log "======== x${mult} UP: ~${want} nodes (${pods} pods), from ${now_nodes} ========"
    set_pods "$pods"; sleep "$SETTLE"
    measure "$CSV" "x${mult}-up" "$(( SECONDS - T0 ))" || warn "scrape failed"
    check_state "x${mult}-up" "$now_nodes" "$CSV"

    if [[ -n "$CEILING" ]]; then
      echo; warn "CEILING at x${mult}: $CEILING"
      warn "Not a failure -- the autoscaler correctly declined. Raise it with:"
      warn "  NODEGROUP_MAX_OVERRIDE=<n> $0 groups $cluster <groups>"
      ok "results: $CSV"; exit 0
    fi
    [[ -n "$BROKE" ]] && { echo; err "BREAKING POINT at x${mult} (scale-up): $BROKE"; err "results: $CSV"; exit 0; }
    ok "x${mult} scale-up survived"

    if [[ "$CHURN" == "1" ]]; then
      peak="$(nodes_now)"
      down=$(( pods * CHURN_FLOOR_PCT / 100 )); (( down < 1 )) && down=1
      log "-------- x${mult} DOWN: collapse to ${down} pods --------"
      set_pods "$down"; sleep "$SETTLE"
      measure "$CSV" "x${mult}-down" "$(( SECONDS - T0 ))" || warn "scrape failed"
      check_state "x${mult}-down" "$peak" "$CSV"
      [[ -n "$BROKE" ]] && { echo; err "BREAKING POINT at x${mult} (scale-down): $BROKE"; err "results: $CSV"; exit 0; }
      after="$(nodes_now)"
      if (( after < peak )); then ok "x${mult} churn: scaled down $peak -> $after"
      else warn "  no scale-down yet ($peak -> $after); run: $0 tune $cluster"; fi
    fi
  done
  echo
  ok "survived every step -- raise the multipliers. results: $CSV"
  ;;

*)
  sed -n '2,30p' "$0"
  exit 1
  ;;
esac
