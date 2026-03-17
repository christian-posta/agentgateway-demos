#!/usr/bin/env bash

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Optional: set CREATE_KIND_CLUSTER=0 to skip kind cluster (use existing cluster)
CREATE_KIND_CLUSTER="${CREATE_KIND_CLUSTER:-1}"

set -a
source .env
set +a

for v in AGENTGATEWAY_LICENSE ENTERPRISE_AGW_VERSION; do
  if [[ -z "${!v}" ]]; then
    echo "Missing required env: $v. Set it in enterprise/.env (see example.env and resources/obo/README.md)." >&2
    exit 1
  fi
done

# --- 1. Kind cluster (optional) ---
if [[ "$CREATE_KIND_CLUSTER" == "1" ]]; then
  if kind get clusters | grep -q '^agw-obo$'; then
    echo "Kind cluster agw-obo already exists; skipping create."
  else
    echo "Creating kind cluster agw-obo..."
    kind create cluster --name agw-obo
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

# --- 5. Controller with Keycloak OBO token exchange (no elicitation) ---
# Keycloak: local Keycloak at localhost:8080, realm mcp-realm (controller uses host.docker.internal from Kind)
KEYCLOAK_JWKS_URL="${KEYCLOAK_JWKS_URL:-http://host.docker.internal:8080/realms/mcp-realm/protocol/openid-connect/certs}"
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
      url: "${KEYCLOAK_JWKS_URL}"
  apiValidator:
    validatorType: remote
    remoteConfig:
      url: "${KEYCLOAK_JWKS_URL}"
  actorValidator:
    validatorType: k8s
  elicitation:
    secretName: ""
EOF

# --- 6. Agent OBO LLM secret ---
kubectl create secret generic google-credentials -n default \
  --from-literal=api-key=${GEMINI_API_KEY}

# --- 7. OBO manifests (gateway, route, agent, UI) ---
kubectl apply -f ./resources/setup/supporting.yaml
kubectl apply -f ./resources/setup/gateway.yaml

kubectl apply -f ./resources/obo/agent-obo.yaml
kubectl apply -f ./resources/obo/agent-obo-ui.yaml
kubectl apply -f ./resources/obo/httproute.yaml
kubectl apply -f ./resources/mcp/public.yaml



echo "Done. See enterprise/resources/obo/README.md for testing (port-forward and curl with a user token)."
