#!/usr/bin/env bash
# =============================================================================
# Prove connectivity to the griffin app and that the SOPS secret is loaded.
#
# Usage:  ./verify.sh       (run from solution/ or anywhere with kubectl
#                            pointed at the minikube profile)
# =============================================================================
set -euo pipefail

NS="griffin"
PORT="${VERIFY_PORT:-18080}"
TIMEOUT="${VERIFY_TIMEOUT:-120}"

fail() { echo "FAIL: $*"; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH"
kubectl config current-context >/dev/null 2>&1 || fail "no kubectl context configured"
echo "kubectl context: $(kubectl config current-context)"

# 1) Deployment is available and the pod is Ready ------------------------------------------------
echo "-- Waiting for deployment/griffin to become available ..."
kubectl -n "$NS" rollout status deployment/griffin --timeout="${TIMEOUT}s" \
  || fail "deployment/griffin not available"
POD=$(kubectl -n "$NS" get pod -l app=griffin -o jsonpath='{.items[0].metadata.name}')
echo "-- pod: $POD"

# 2) Tunnel the ClusterIP service to localhost ---------------------------------------------------
echo "-- Port-forwarding svc/griffin to 127.0.0.1:${PORT} ..."
kubectl -n "$NS" port-forward "svc/griffin" "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

BODY=""
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    BODY=$(curl -sf "http://127.0.0.1:${PORT}/" 2>/dev/null || true)
    BODY="${BODY:-$(curl -s "http://127.0.0.1:${PORT}/" 2>/dev/null || true)}"
    break
  fi
  sleep 0.5
done

[ -n "$BODY" ] || fail "could not reach the app through port-forward"

echo
echo "-- GET / --"
echo "$BODY"
echo

# 3) Assertions ----------------------------------------------------------------------------------
echo "$BODY" | grep -q "Secret loaded: yes" || fail "SECRET_TOKEN was not loaded into the app"
echo "$BODY" | grep -q "Greetings from deployment.yaml" \
  || echo 'WARN: GREETING did not match "Greetings from deployment.yaml" (may be expected)'

curl -sf "http://127.0.0.1:${PORT}/healthz" | grep -q "ok" || fail "/healthz did not return ok"

echo "PASS: app reachable on / and /healthz; SECRET_TOKEN loaded from the SOPS-encrypted secret."
