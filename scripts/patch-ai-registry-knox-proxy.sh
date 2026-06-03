#!/usr/bin/env bash
# Print or run Knox JVM proxy patch (DSE-48642) for Cloudera AI Registry or AI Inference.
#
# Usage:
#   ./scripts/patch-ai-registry-knox-proxy.sh              # print CloudShell commands
#   ./scripts/patch-ai-registry-knox-proxy.sh --apply      # run kubectl (only if API reachable)
#
# Prerequisites:
#   - aws-egress applied; run from repo root or set EGRESS_DIR
#   - For --apply: KUBECONFIG pointing at Registry OR Inference EKS and working kubectl (e.g. EKS CloudShell)
#   - Registry: docs/ai-registry-full-private.md
#   - Inference: docs/ai-inference-full-private.md (different liftie-* cluster)

set -euo pipefail

APPLY=false
EGRESS_DIR="${EGRESS_DIR:-aws-egress}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found" >&2
  exit 1
fi

PROXY_HOST="$(terraform -chdir="${EGRESS_DIR}" output -raw egress_proxy_private_ip 2>/dev/null)" || {
  echo "Failed to read egress_proxy_private_ip from ${EGRESS_DIR}. Run aws-egress apply first." >&2
  exit 1
}
PROXY_PORT="$(terraform -chdir="${EGRESS_DIR}" output -raw egress_proxy_port 2>/dev/null || echo "3128")"
KNOX_OPTS="$(terraform -chdir="${EGRESS_DIR}" output -raw knox_jvm_proxy_opts 2>/dev/null)" || {
  KNOX_OPTS="-Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=${PROXY_PORT} -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true"
}

run_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found" >&2
    return 1
  fi
  kubectl "$@"
}

cat <<EOF
=== Cloudera AI Registry / Inference — Knox proxy patch (DSE-48642) ===

Proxy (from aws-egress): ${PROXY_HOST}:${PROXY_PORT}
KNOX_GATEWAY_DBG_OPTS:
  ${KNOX_OPTS}

Run the following in AWS EKS console → Connect → CloudShell
- AI Registry: target cluster liftie-* for your Registry (namespace knox)
- AI Inference: target cluster liftie-* for your Compute Cluster (namespace knox)
  See docs/ai-inference-full-private.md

--- copy from here ---
kubectl get pods -n knox
kubectl auth can-i update deployment -n knox

kubectl set env deployment/knox -n knox \\
  KNOX_GATEWAY_DBG_OPTS='${KNOX_OPTS}'

kubectl get pods -n knox -w
# Ctrl+C when one knox pod is Running 1/1

kubectl rollout restart deployment model-registry-v2 -n mlx
kubectl get pods -n mlx
--- copy until here ---

Then verify Model Hub (local browser + SOCKS for *.cloudera.site):
  GET .../api/v2/models should not return 401.

Doc: docs/ai-registry-full-private.md
EOF

if [[ "${APPLY}" != "true" ]]; then
  exit 0
fi

echo ""
echo "=== Applying via local kubectl (KUBECONFIG=${KUBECONFIG:-default}) ==="

run_kubectl get pods -n knox
run_kubectl set env deployment/knox -n knox "KNOX_GATEWAY_DBG_OPTS=${KNOX_OPTS}"
run_kubectl rollout status deployment/knox -n knox --timeout=300s
run_kubectl rollout restart deployment model-registry-v2 -n mlx
run_kubectl rollout status deployment/model-registry-v2 -n mlx --timeout=300s

echo "Done."
