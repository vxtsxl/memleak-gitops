#!/usr/bin/env bash
# Watch pods get OOMKilled (restart counter climbs, last state = OOMKilled)
kubectl -n memleak get pods -w &
sleep 1
while true; do
  kubectl -n memleak get pods -o custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST:.status.containerStatuses[0].lastState.terminated.reason
  sleep 15
done
