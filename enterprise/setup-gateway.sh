# pick up local env variables
set -a
source .env
set +a

# Create namespace
kubectl create namespace agentgateway-system

# Install Gateway API
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# Install CRDs
helm upgrade -i --create-namespace --namespace agentgateway-system \
    --version $ENTERPRISE_AGW_VERSION enterprise-agentgateway-crds \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds


# Install controller / control plane
helm upgrade -i -n agentgateway-system enterprise-agentgateway oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
--create-namespace \
--version $ENTERPRISE_AGW_VERSION \
--set-string licensing.licenseKey=$AGENTGATEWAY_LICENSE \
-f -<<EOF
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
      url: "https://ceposta-solo.auth0.com/.well-known/jwks.json"
  actorValidator:
    validatorType: k8s   
  apiValidator:
    validatorType: remote
    remoteConfig:
      url: "https://ceposta-solo.auth0.com/.well-known/jwks.json"
controller:
  extraEnv:
    CALLBACK_URL: "http://localhost:4000/age/elicitations"       
EOF


# Can later get values from the installation with this:

# helm get values enterprise-agentgateway -n agentgateway-system  

# Install supporting components
kubectl apply -f ./resources/setup/supporting.yaml
kubectl apply -f ./resources/setup/gateway.yaml

# Optional: dummy failover service (used by /failover/openai route demo)
kubectl apply -f ./resources/supporting/failover-429.yaml



# Install AgentGateway UI which helps surface the elicitaitons
export OIDC_BACKEND=IwGCb89vj2iK12ja8bpZN9u4NIrKjpLZ
export OIDC_FRONTEND=D8wCng8JIZFZM8zY6wJGDRcjjs7VBivh
export BACKEND_CLIENT_SECRET=$AUTH0_CLIENT_ID
export OIDC_ISSUER=https://ceposta-solo.auth0.com/

export KAGENT_ENT_VERSION=0.3.9
export KAGENT_MGMT_CHART=oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management

helm upgrade -i kagent-mgmt \
  $KAGENT_MGMT_CHART \
  -n kagent --create-namespace \
  --version "$KAGENT_ENT_VERSION" \
  -f - <<EOF
imagePullSecrets: []
global:
  imagePullPolicy: IfNotPresent

oidc:
  issuer: ${OIDC_ISSUER}

rbac:
  roleMapping:
    roleMapper: "claims.permissions.transformList(i, v, v in rolesMap, rolesMap[v])"
    roleMappings:
      "role:admin": "global.Admin"
      "role:reader": "global.Reader"
      "role:writer": "global.Writer"

service:
  type: LoadBalancer
  clusterIP: ""

# --- Enable Solo UI for AgentGateway (required) ---
products:
  kagent:
    enabled: false
  agentgateway:
    enabled: true
    namespace: agentgateway-system
  mesh:
    enabled: false
  agentregistry:
    enabled: false

ui:
  backend:
    oidc:
      clientId: ${OIDC_BACKEND}
      secret: ${BACKEND_CLIENT_SECRET}
  frontend:
    oidc:
      clientId: ${OIDC_FRONTEND}

clickhouse:
  enabled: true

tracing:
  verbose: true
EOF