#!/usr/bin/env bash
# Runs one scenario: deploys the client in the given mode, puts it under load, triggers the
# event on one pod, and prints what happened. Evidence is saved under logs/<mode>-<trigger>-<ts>/.
set -euo pipefail

usage() { echo "usage: $0 <broken|fixed> <delete|liveness|close-cache>" >&2; exit 2; }
MODE="${1:-}"; TRIGGER="${2:-}"
[[ "${MODE}" == broken || "${MODE}" == fixed ]] || usage
[[ "${TRIGGER}" == delete || "${TRIGGER}" == liveness || "${TRIGGER}" == close-cache ]] || usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K=(kubectl --context k3d-geode-repro)
OUT="${ROOT}/logs/${MODE}-${TRIGGER}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT}"

echo "== Stopping load"
"${K[@]}" delete pod load --ignore-not-found --wait=true >/dev/null

echo "== Deploying client (${MODE}) with fresh pods"
"${K[@]}" apply -f "${ROOT}/k8s/client-${MODE}.yaml" >/dev/null
"${K[@]}" rollout restart deploy/repro-client >/dev/null
"${K[@]}" rollout status deploy/repro-client --timeout=300s

echo "== Starting load"
"${K[@]}" apply -f "${ROOT}/k8s/load.yaml" >/dev/null
"${K[@]}" wait --for=condition=Ready pod/load --timeout=120s >/dev/null

# Pick a Ready, non-terminating pod from the new rollout.
POD="$("${K[@]}" get pods -l app=repro-client,mode="${MODE}" \
  -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.metadata.name}{"\n"}{end}' \
  | awk -F'|' '$1=="" {print $2; exit}')"
POD_IP="$("${K[@]}" get pod "${POD}" -o jsonpath='{.status.podIP}')"
echo "== Target pod: ${POD} (${POD_IP})"

"${K[@]}" logs -f "${POD}" > "${OUT}/client.log" 2>&1 &
LOG_PID=$!

sleep 8   # let requests (3s each) pile up on both pods
TRIGGER_TIME="$(date -u +%H:%M:%S)"
echo "== Trigger '${TRIGGER}' at ${TRIGGER_TIME} UTC"

case "${TRIGGER}" in
  delete)
    "${K[@]}" delete pod "${POD}" --wait=false >/dev/null
    "${K[@]}" wait --for=delete pod/"${POD}" --timeout=120s >/dev/null
    ;;
  liveness)
    "${K[@]}" exec load -- curl -s -X POST "http://${POD_IP}:8080/admin/break-liveness" >/dev/null
    for _ in $(seq 1 90); do
      restarts="$("${K[@]}" get pod "${POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
      [[ "${restarts}" -ge 1 ]] && break
      sleep 2
    done
    "${K[@]}" logs "${POD}" --previous > "${OUT}/client.log" 2>&1
    "${K[@]}" describe pod "${POD}" > "${OUT}/describe.txt" 2>&1
    ;;
  close-cache)
    "${K[@]}" exec load -- curl -s -X POST "http://${POD_IP}:8080/admin/close-cache" >/dev/null
    sleep 15
    "${K[@]}" get pod "${POD}" -o wide > "${OUT}/pod-after.txt" 2>&1
    ;;
esac

sleep 3
kill "${LOG_PID}" 2>/dev/null || true
wait "${LOG_PID}" 2>/dev/null || true
"${K[@]}" get events --field-selector involvedObject.name="${POD}" \
  --sort-by=.lastTimestamp > "${OUT}/events.txt" 2>&1 || true
"${K[@]}" logs load > "${OUT}/load.log" 2>&1 || true

LOG="${OUT}/client.log"
echo
echo "================ SUMMARY: ${MODE} / ${TRIGGER} (pod ${POD}) ================"
echo "Failed Account puts (CacheClosedException): $(grep -c 'Exception while put Account' "${LOG}" || true)"
echo "Failed config polls  (CacheClosedException): $(grep -c 'Error encountered during get operation' "${LOG}" || true)"
echo
echo "-- Shutdown sequence in the client log:"
grep -E 'REPRO mode|VM is exiting|Now closing|Commencing graceful shutdown|Graceful shutdown complete|REPRO (config poller|closing|liveness)' "${LOG}" || echo "(none)"
echo
echo "-- First failed put:"
grep -m1 -A10 'Exception while put Account' "${LOG}" || echo "(none)"
echo
echo "-- HTTP codes seen by the load pod from ${TRIGGER_TIME} UTC onward (000 = connection dropped):"
awk -v t="${TRIGGER_TIME}" '$1 >= t {print $3}' "${OUT}/load.log" | sort | uniq -c || true
if [[ "${TRIGGER}" == liveness ]]; then
  echo
  echo "-- Container status after restart:"
  grep -E 'Last State|Reason|Exit Code|Restart Count' "${OUT}/describe.txt" || true
fi
if [[ "${TRIGGER}" == close-cache ]]; then
  echo
  echo "-- Pod after close-cache (still Running/Ready):"
  cat "${OUT}/pod-after.txt"
  echo "(The pod keeps failing until it is replaced: kubectl --context k3d-geode-repro delete pod ${POD})"
fi
echo
echo "-- Pod events:"
grep -E 'Killing|Unhealthy|probe' "${OUT}/events.txt" || echo "(none)"
echo
echo "Evidence saved in ${OUT}"
