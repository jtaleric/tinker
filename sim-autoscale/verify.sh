#!/usr/bin/env bash
# Offline verification suite. Creates nothing on the cluster.
#
# Runs the checks that can be made before the ~20-minute hosted control plane
# exists:
#   1. shell syntax
#   2. the set -e short-circuit trap (a false `[[ ]] && x` as the last line of
#      a sourced file or function silently aborts the caller)
#   3. nodetypes.yaml validation, including negative cases
#   4. manifest rendering
#   5. manifest validation against real CRD schemas, offline
#   6. a negative control proving the schema validator actually fails
#
# Requires generated/hypershift-install.yaml, which is produced by:
#   KUBECONFIG=./kubeconfig ./bin/hypershift install render \
#     --hypershift-image <img> --format=yaml > generated/hypershift-install.yaml
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
RC=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; RC=1; }
sec()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

sec "1. shell syntax"
for f in ./*.sh; do
  bash -n "$f" 2>/dev/null && pass "$f" || fail "$f has a syntax error"
done

sec "2. set -e short-circuit trap"
# A false `[[ ]] && cmd` is harmless mid-script but fatal as the final command
# of a sourced file or a function. Check only those positions.
# The regex must live in a variable: an unquoted && or | inside [[ =~ ]] is a
# bash parse error.
shortcircuit_re='^[[:space:]]*\[\[.*\]\][[:space:]]*&&'
for f in ./*.sh; do
  last="$(grep -vE '^[[:space:]]*(#|$)' "$f" | tail -1)"
  if [[ "$last" =~ $shortcircuit_re ]]; then
    fail "$f ends in a short-circuit that will abort callers under set -e"
  else
    pass "$f does not end in a fatal short-circuit"
  fi
done
# env.sh is sourced by everything, so prove it survives being sourced.
if bash -c 'set -euo pipefail; source ./env.sh; source ./lib.sh; exit 0' 2>/dev/null; then
  pass "env.sh and lib.sh are safe to source under set -e"
else
  fail "sourcing env.sh/lib.sh aborts under set -e"
fi

sec "3. nodetypes.yaml validation"
if ./gen-nodetypes.sh >/dev/null 2>&1; then
  pass "nodetypes.yaml accepted"
else
  fail "nodetypes.yaml rejected"
fi

t="$(mktemp -d)"
cat > "$t/dup.yaml" <<'EOF'
nodetypes:
  - {name: a, cpu: "8", memory: 32G, zone: z1, instanceType: m5, min: 0, max: 5}
  - {name: a, cpu: "8", memory: 32G, zone: z2, instanceType: m5, min: 0, max: 5}
EOF
cat > "$t/badname.yaml" <<'EOF'
nodetypes:
  - {name: Bad_Name, cpu: "8", memory: 32G, zone: z1, instanceType: m5, min: 0, max: 5}
EOF
cat > "$t/minmax.yaml" <<'EOF'
nodetypes:
  - {name: a, cpu: "8", memory: 32G, zone: z1, instanceType: m5, min: 9, max: 5}
EOF
cat > "$t/missing.yaml" <<'EOF'
nodetypes:
  - {name: a, cpu: "8", zone: z1, instanceType: m5, min: 0, max: 5}
EOF
cat > "$t/empty.yaml" <<'EOF'
nodetypes: []
EOF
for c in dup badname minmax missing empty; do
  if NODETYPES_FILE="$t/$c.yaml" ./gen-nodetypes.sh >/dev/null 2>&1; then
    fail "invalid nodetypes '$c' was accepted"
  else
    pass "rejected invalid nodetypes: $c"
  fi
done
rm -rf "$t"

sec "4. manifest rendering (every cluster profile)"
# Render each profile so a version-specific mistake in profiles/*.env is caught
# here rather than 20 minutes into a control-plane rollout.
PROFILES=()
for p in profiles/*.env; do
  [[ -e "$p" ]] || continue
  PROFILES+=("$(basename "$p" .env)")
done
[[ ${#PROFILES[@]} -eq 0 ]] && PROFILES=("")

RENDERED=()
for prof in "${PROFILES[@]}"; do
  label="${prof:-default}"
  out="generated/_verify/${label}"
  mkdir -p "$out"
  if CLUSTER_PROFILE="$prof" RENDER=1 GENERATED_DIR="$PWD/$out" \
       ./create-hostedcluster.sh > "$out/render-hc.yaml" 2>/dev/null; then
    pass "create-hostedcluster.sh renders [$label]"
    RENDERED+=("$out/render-hc.yaml")
  else
    fail "create-hostedcluster.sh failed to render [$label]"
  fi
  if CLUSTER_PROFILE="$prof" RENDER=1 GENERATED_DIR="$PWD/$out" \
       ./wire-capi.sh > "$out/render-capi.yaml" 2>/dev/null; then
    pass "wire-capi.sh renders [$label]"
    RENDERED+=("$out/render-capi.yaml")
  else
    fail "wire-capi.sh failed to render [$label]"
  fi
done

sec "5. schema validation against real CRDs"
HS_RENDER=generated/_shared/hypershift-install.yaml
CAPK_RENDER=generated/_shared/capk-infrastructure-components.yaml
CRDS=("$HS_RENDER")
[[ -s "$CAPK_RENDER" ]] && CRDS+=("$CAPK_RENDER")
if [[ ! -s "$HS_RENDER" ]]; then
  fail "$HS_RENDER missing -- see header comment"
else
  # Capture to a variable rather than piping into `grep -q`: grep -q exits on
  # the first match and SIGPIPEs the producer, which under `set -o pipefail`
  # makes a successful match look like a failed pipeline.
  out="$(python3 -I validate-manifests.py --crds "${CRDS[@]}" \
          --manifests "${RENDERED[@]}" 2>&1)"
  if grep -q "0 problem" <<<"$out"; then
    pass "all rendered manifests validate ($((${#RENDERED[@]})) files, every profile)"
  else
    fail "schema validation reported problems"
    grep -E "FAIL|MISS" <<<"$out" | head
  fi

  sec "6. negative control"
  mkdir -p generated/_verify
  # Corrupt ANY replicas value, not literally "replicas: 0" -- once min-size
  # clamping landed, rendered manifests no longer contain a zero and the
  # negative control silently stopped corrupting anything.
  sed -E 's/^([[:space:]]*)replicas: [0-9]+$/\1replicas: "zero"/' "${RENDERED[-1]}" > generated/_verify/bad.yaml
  grep -q 'replicas: "zero"' generated/_verify/bad.yaml || fail "negative control could not corrupt the manifest"
  bad_out="$(python3 -I validate-manifests.py --crds "${CRDS[@]}" \
              --manifests generated/_verify/bad.yaml 2>&1)"
  if grep -q "FAIL" <<<"$bad_out"; then
    pass "validator correctly rejects a corrupted manifest"
  else
    fail "validator did NOT reject a corrupted manifest -- it is not proving anything"
  fi
  rm -f generated/_verify/bad.yaml
fi

echo
if [[ "$RC" == "0" ]]; then
  printf '\033[0;32mall offline checks passed\033[0m\n'
else
  printf '\033[0;31msome checks failed\033[0m\n'
fi
exit "$RC"
