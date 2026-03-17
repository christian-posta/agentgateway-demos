#!/usr/bin/env bash
# End-to-end setup for Microsoft Entra OBO with Enterprise Agentgateway.
# Creates a kind cluster (agw-msft-obo), installs Gateway API + Agentgateway with Entra OBO config,
# and applies the msft-obo manifests. Requires .env with license, version, and Entra variables.
# See enterprise/resources/msft-obo/README.md for full guide.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Optional: set CREATE_KIND_CLUSTER=0 to skip kind cluster (use existing cluster)
CREATE_KIND_CLUSTER="${CREATE_KIND_CLUSTER:-1}"

set -a
source .env
set +a

for v in AGENTGATEWAY_LICENSE ENTERPRISE_AGW_VERSION ENTRA_TENANT_ID ENTRA_MIDDLETIER_CLIENT_ID ENTRA_DOWNSTREAM_SCOPE ENTRA_OBO_CLIENT_SECRET; do
  if [[ -z "${!v}" ]]; then
    echo "Missing required env: $v. Set it in enterprise/.env (see example.env and resources/msft-obo/README.md)." >&2
    exit 1
  fi
done

# --- 1. Kind cluster (optional) ---
if [[ "$CREATE_KIND_CLUSTER" == "1" ]]; then
  if kind get cluster --name agw-msft-obo &>/dev/null; then
    echo "Kind cluster agw-msft-obo already exists; skipping create."
  else
    echo "Creating kind cluster agw-msft-obo..."
    kind create cluster --name agw-msft-obo
  fi
fi

# --- 2. Namespace ---
kubectl create namespace agentgateway-system --dry-run=client -o yaml | kubectl apply -f -

# --- 3. Gateway API ---
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# --- 4. Enterprise Agentgateway CRDs ---
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "$ENTERPRISE_AGW_VERSION" enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds

# --- 5. Controller with Entra OBO token exchange (no elicitation) ---
helm upgrade -i -n agentgateway-system enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --create-namespace \
  --version "$ENTERPRISE_AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE" \
  -f - <<EOF
gatewayClassParametersRefs:
  enterprise-agentgateway:
    group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayParameters
    name: agentgateway-params
    namespace: agentgateway-system
tokenExchange:
  enabled: true
  issuer: "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
  tokenExpiration: 24h
  subjectValidator:
    validatorType: remote
    remoteConfig:
      url: "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys"
  apiValidator:
    validatorType: remote
    remoteConfig:
      url: "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys"
  actorValidator:
    validatorType: k8s
  elicitation:
    secretName: ""
EOF

# --- 6. Entra OBO client secret ---
kubectl create secret generic entra-obo-client-secret \
  --namespace agentgateway-system \
  --from-literal=client_secret="$ENTRA_OBO_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 7. Msft-OBO manifests (params, gateway, route, backends, echo, policies) ---
kubectl apply -f ./resources/msft-obo/gateway-params.yaml
kubectl apply -f ./resources/msft-obo/entra-jwks-backend.yaml
kubectl apply -f ./resources/msft-obo/gateway-and-route.yaml

# Policies need env substitution
export ENTRA_TENANT_ID ENTRA_MIDDLETIER_CLIENT_ID ENTRA_DOWNSTREAM_SCOPE
envsubst < ./resources/msft-obo/jwt-auth-policy.yaml | kubectl apply -f -
envsubst < ./resources/msft-obo/entra-obo-policy.yaml | kubectl apply -f -

echo "Done. See enterprise/resources/msft-obo/README.md for testing (port-forward and curl with a user token)."
