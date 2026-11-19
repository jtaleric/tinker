#!/usr/bin/env bash
# Shared helpers. Source after env.sh.

# --- logging ------------------------------------------------------------
_ts() { date -u +%H:%M:%S; }
log()  { printf '\033[0;34m[%s]\033[0m %s\n'       "$(_ts)" "$*" >&2; }
ok()   { printf '\033[0;32m[%s] OK\033[0m %s\n'    "$(_ts)" "$*" >&2; }
warn() { printf '\033[0;33m[%s] WARN\033[0m %s\n'  "$(_ts)" "$*" >&2; }
err()  { printf '\033[0;31m[%s] ERROR\033[0m %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- preflight ----------------------------------------------------------
need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

need_cluster() {
  [[ -r "$KUBECONFIG" ]] || die "kubeconfig not readable: $KUBECONFIG"
  oc whoami >/dev/null 2>&1 || die "cannot authenticate to the management cluster using $KUBECONFIG"
}

# --- apply --------------------------------------------------------------
# Reads a manifest on stdin. With DRY_RUN=1 it prints the manifest and
# validates it against the live API server without persisting anything.
kapply() {
  local manifest
  manifest="$(cat)"
  if [[ "$RENDER" == "1" ]]; then
    # Offline: print only, never contact the API server.
    printf '%s\n---\n' "$manifest"
  elif [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n---\n' "$manifest"
    printf '%s' "$manifest" | oc apply --dry-run=server -f - >&2
  else
    printf '%s' "$manifest" | oc apply -f -
  fi
}

# Delete that tolerates absence, and is silent under DRY_RUN.
kdelete() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "(dry-run) would delete: $*"
    return 0
  fi
  oc delete --ignore-not-found "$@"
}

# Delete CAPI objects without the risk of hanging forever.
#
# CAPI puts a cluster.x-k8s.io/machinedeployment finalizer on MachineDeployments
# and only removes it when its controller can reconcile the deletion. If the
# owning CAPI Cluster does not exist -- which is the case before
# wire-capi.sh runs, and again after it is torn down -- the controller never
# clears the finalizer and a plain `oc delete` blocks indefinitely.
#
# So: delete without waiting, give the controller a bounded chance to do it
# properly, then strip finalizers if it has not.
#
# force_delete <timeout-seconds> <kind> <name> -n <namespace>
force_delete() {
  local timeout="$1" kind="$2" name="$3"; shift 3
  if [[ "$DRY_RUN" == "1" ]]; then
    log "(dry-run) would delete $kind/$name"
    return 0
  fi

  oc delete "$kind" "$name" "$@" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  local deadline=$(( SECONDS + timeout ))
  while oc get "$kind" "$name" "$@" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      warn "$kind/$name still present after ${timeout}s; removing finalizers"
      oc patch "$kind" "$name" "$@" --type=merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      sleep 2
      break
    fi
    sleep 2
  done
}

# --- hosted cluster access ----------------------------------------------
# hoc = "hosted oc": run oc against the hosted cluster rather than the
# management cluster.
hoc() {
  [[ -r "$HC_KUBECONFIG" ]] || die "hosted kubeconfig not found: $HC_KUBECONFIG (run create-hostedcluster.sh)"
  oc --kubeconfig "$HC_KUBECONFIG" "$@"
}

# --- waiting ------------------------------------------------------------
# wait_for <timeout-seconds> <description> <command...>
# Polls the command until it exits 0, or fails after the timeout.
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))
  log "waiting (up to ${timeout}s) for: $desc"
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      err "timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 5
  done
  ok "$desc"
}

# --- Prometheus ---------------------------------------------------------
# Always prefer this over `oc get --raw /metrics` for apiserver metrics.
# That endpoint is load-balanced across control-plane members and each
# kube-apiserver keeps its own counters, so consecutive reads of the same
# counter disagree (observed: 24080 -> 22892 -> 20087 within seconds) and
# computed deltas are meaningless. Prometheus scrapes every member.
PROM_POD="${PROM_POD:-prometheus-k8s-0}"
PROM_NS="${PROM_NS:-openshift-monitoring}"

# promq <promql> -> raw JSON on stdout
promq() {
  oc exec -n "$PROM_NS" "$PROM_POD" -c prometheus -- \
    curl -sG --data-urlencode "query=$1" \
    http://localhost:9090/api/v1/query 2>/dev/null
}

# promq_scalar <promql> -> single float (0 if absent)
promq_scalar() {
  promq "$1" | python3 -I "$SIM_ROOT/promq.py" --scalar
}

# --- CAPI reconcile nudge -----------------------------------------------
# Workaround for a real gap: when a hollow kubelet registers its Node in the
# hosted cluster, CAPI's Machine controller is not woken up. The Machine sits
# at phase=Provisioned with an empty status.nodeRef until the next periodic
# resync (~10 min), even though the Node exists and the providerIDs match.
#
# While nodeRef is empty the autoscaler counts the node as "unregistered",
# which distorts both scale-up accounting and scale-down eligibility -- so for
# a lab measuring autoscaler timing this must not be left to the resync.
#
# Touching an annotation forces an immediate reconcile, after which the
# controller links the Node and the Machine moves to Running.
nudge_pending_machines() {
  local pending
  pending="$(oc get machines -n "$HCP_NS" -o json 2>/dev/null \
    | jq -r '.items[] | select((.status.nodeRef.name // "") == "")
             | select((.status.phase // "") == "Provisioned")
             | .metadata.name' 2>/dev/null)"
  [[ -z "$pending" ]] && return 0
  local n=0
  for m in $pending; do
    oc annotate machine "$m" -n "$HCP_NS" \
      "sim-autoscale.io/nudge=$(date +%s)" --overwrite >/dev/null 2>&1 || true
    n=$(( n + 1 ))
  done
  log "nudged $n machine(s) awaiting nodeRef"
}

# --- release image ------------------------------------------------------
# Defaults the hosted cluster release image to the management cluster's own,
# which is guaranteed to be pullable with the cluster pull-secret.
resolve_release_image() {
  if [[ -z "$RELEASE_IMAGE" ]]; then
    RELEASE_IMAGE="$(oc get clusterversion version -o jsonpath='{.status.desired.image}')"
    [[ -n "$RELEASE_IMAGE" ]] || die "could not resolve a release image from the management cluster"
    export RELEASE_IMAGE
  fi
  log "release image: $RELEASE_IMAGE"
}

# --- nodetypes.yaml -----------------------------------------------------
# Emits one TSV line per node type: name cpu memory zone instanceType min max
read_nodetypes() {
  [[ -r "$NODETYPES_FILE" ]] || die "nodetypes file not readable: $NODETYPES_FILE"
  yq -r '.nodetypes[] | [.name, .cpu, .memory, .zone, .instanceType, .min, .max] | @tsv' "$NODETYPES_FILE"
}

# Fails loudly on a malformed nodetypes.yaml rather than rendering bad YAML.
validate_nodetypes() {
  local count
  count="$(yq -r '.nodetypes | length' "$NODETYPES_FILE" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || die "no nodetypes defined in $NODETYPES_FILE"

  local seen=""
  while IFS=$'\t' read -r name cpu memory zone itype min max; do
    [[ -n "$name" && "$name" != "null" ]] || die "nodetype with empty name in $NODETYPES_FILE"
    [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
      || die "nodetype '$name' is not a valid DNS-1123 label"
    for f in cpu:"$cpu" memory:"$memory" zone:"$zone" instanceType:"$itype"; do
      [[ "${f#*:}" != "null" && -n "${f#*:}" ]] || die "nodetype '$name' is missing field ${f%%:*}"
    done
    [[ "$min" =~ ^[0-9]+$ ]] || die "nodetype '$name': min must be an integer, got '$min'"
    [[ "$max" =~ ^[0-9]+$ ]] || die "nodetype '$name': max must be an integer, got '$max'"
    (( max >= min )) || die "nodetype '$name': max ($max) must be >= min ($min)"
    case " $seen " in *" $name "*) die "duplicate nodetype name: $name";; esac
    seen="$seen $name"
  done < <(read_nodetypes)
  ok "nodetypes.yaml valid ($count node types)"
}
