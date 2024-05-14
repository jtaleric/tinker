#!/usr/bin/bash

oc apply -f simple.yml

function check_job {
  jobs=$(oc get pytorchjob/pytorch-simple -o=jsonpath='{.status.replicaStatuses.Worker.succeeded}')
  echo "Completed replicas - $jobs"
  if [[ $jobs -eq 10 ]]; then
    return 0
  else
    return 1
  fi
}

iter=0
while true; do
  if check_job; then
    echo "Job Completed - Iteration $iter"
    oc delete pytorchjob/pytorch-simple
    echo "Starting new job"
    oc apply -f simple.yml
    iter=$((iter+1))
  else
    echo "Job still running for iteration $iter, sleeping for 5min"
    sleep 300
  fi
done
