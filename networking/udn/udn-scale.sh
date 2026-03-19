#!/bin/bash
set -u 

# Configuration
KUBE_BURNER_BIN="./bin/amd64/kube-burner-ocp"
STABLE_WAIT="3m"

# Helper function for consistent logging with timestamps
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

iter=1

while true; do
  log "--- Starting Iteration ${iter} ---"
  
  # 2. Native Bash Arithmetic (No need for 'bc')
  num_udns=$((25 * iter))
  log "Target udns: $num_udns"

  # 3. Run Benchmark
  # Note: RANDOM is a reserved Bash variable. Using it as an ENV var name works 
  # for the subprocess, but it is unusual. Ensure kube-burner expects exactly 'RANDOM'.
  log "Running kube-burner..."
  RANDOM="rook-run-$iter" SIMPLE=false JOB_PAUSE=60s \
  $KUBE_BURNER_BIN udn-density-pods \
    --iterations "$num_udns" \
    --es-server="https://$ES_SERVER" \
    --es-index=ripsaw-kube-burner \
    --gc=false \
    --layer3=false \
    --pprof=true \
    --pod-ready-threshold="2h" \
    --timeout="10h" \
    --uuid="l2-udn-density-$iter"

  # Capture exit code of kube-burner
  KB_EXIT_CODE=$?
  if [ $KB_EXIT_CODE -ne 0 ]; then
    log "ERROR: Kube-burner failed on iteration ${iter}. Exiting loop."
    break
  fi

  log "Sleeping for 60s..."
  sleep 60

  # 4. Data Collection (Safer directory handling)
  DIR_NAME="mg-$iter"
  log "Collecting must-gather into $DIR_NAME..."
  oc adm must-gather --dest-dir="$DIR_NAME"

  # Move pprof data if it exists
  if [ -d "pprof-data" ]; then
      mv pprof-data "pprof-data-$iter"
  else
      log "WARN: pprof-data directory not found."
  fi

  # 5. Cleanup Labels
  # We filter only namespaces that actually have the label to speed this up and reduce noise
  #log "Cleaning up namespace labels..."
  #kubectl get ns -l kube-burner-job -o custom-columns=:metadata.name --no-headers | \
  #xargs -I {} kubectl label namespace {} kube-burner-job- > /dev/null 2>&1

  # 6. Cluster Stability Check
  log "Waiting for cluster stability (Minimum: $STABLE_WAIT)..."
  oc adm wait-for-stable-cluster --minimum-stable-period="$STABLE_WAIT"
  
  if [ $? -ne 0 ]; then
      log "CRITICAL: Cluster failed to stabilize. Stopping test."
      break
  fi

  # 7. Increment the counter (Critical fix!)
  ((iter++))
  log "Iteration $iter setup complete. Proceeding..."
  echo "------------------------------------------------"
done
