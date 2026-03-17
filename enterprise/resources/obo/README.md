We are going to deploy an AI agent that uses Google Gemini model: `gemini-2.5-flash-lite`

This agent is programmed to take a user's access token, a Kubernetes service account token (ie, from `/var/run/secrets/kubernetes.io/serviceaccount/token` but is configurable in the Agent source code), and pass that to the Agentgateway STS (on port 7777 of the controller). 

Said more clearly, AGW is providing the STS to combine agent and user identity.

There is another mode where we have the AGW do the exchange, but this demo does not show that at the moment. 

This STS will evaluate the tokens, and decide based on policy whether the OBO relationships is allowed. At the moment, the only policy check is `may_act` on the User's access token. This must match the service account of the actor, e.g., `system:serviceaccount:default:agent-sa`. 

TODO: for the rest of the demo, we can now use the OBO token to check authorization. ie, "can agent foo call these tools on behalf of user John"

Agentgateway token exchange settings must trust the same identity provider as the Agent UI. This demo uses **local Keycloak** at `http://localhost:8080`, realm **mcp-realm**. From inside the cluster (e.g. Kind), the controller reaches Keycloak via `host.docker.internal:8080`.

```json
tokenExchange:
  enabled: true
  issuer: "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
  tokenExpiration: 24h
  subjectValidator:
    validatorType: remote
    remoteConfig:
      url: "http://host.docker.internal:8080/realms/mcp-realm/protocol/openid-connect/certs"
  apiValidator:
    validatorType: remote
    remoteConfig:
      url: "http://host.docker.internal:8080/realms/mcp-realm/protocol/openid-connect/certs"
  actorValidator:
    validatorType: k8s
```

`setup-obo.sh` sets this automatically; override with `KEYCLOAK_JWKS_URL` if your Keycloak is elsewhere.

## Set up

Deploy into default namespace.

```bash
# this needs to be gemini api key
cd enterprise
source .env
kubectl create secret generic google-credentials \
  --from-literal=api-key=${GEMINI_API_KEY}
```

Then deploy agent-obo:

```bash
kubectl apply -f resources/obo/agent-obo.yaml
kubectl apply -f resources/obo/agent-obo-ui.yaml
kubectl apply -f resources/obo/httproute.yaml
```


This demo uses **local Keycloak** at `http://localhost:8080`, realm **mcp-realm**. Configure a client in that realm:

- **Client ID:** `kagent-ui`
- **Redirect URI:** `http://localhost:3000/callback`
- **Web origin:** `http://localhost:3000/`

Add a protocol mapper to the client's default scope: a **Hardcoded Claim** of type JSON with value:

```json
{"sub":"system:serviceaccount:default:agent-sa"}
```

This populates the `may_act` claim so the AgentGateway STS can validate the OBO relationship. 

Port forward the agent-gateway (running on 8080) to local port 3000

Go to URL in your browser:

```
http://localhost:3000/obo
```

You'll need to login to the agent UI with user. 

User's access token that gets exchanged (note the may_act claim):

```json
{
  "exp": 1769367475,
  "iat": 1769363875,
  "auth_time": 1769363875,
  "jti": "onrtac:c0be0799-05ba-4322-88ed-bdd937447615",
  "iss": "http://localhost:8080/realms/mcp-realm",
  "aud": "account",
  "sub": "e3349fa1-02c5-4d80-b497-4e7963b20148",
  "typ": "Bearer",
  "azp": "kagent-ui",
  "sid": "2507610d-5832-4360-8787-ac8535801431",
  "acr": "1",
  "allowed-origins": [
    "http://localhost:3000"
  ],
  "realm_access": {
    "roles": [
      "supply-chain",
      "default-roles-mcp-realm",
      "ai-agents",
      "offline_access",
      "uma_authorization"
    ]
  },
  "resource_access": {
    "account": {
      "roles": [
        "manage-account",
        "manage-account-links",
        "view-profile"
      ]
    }
  },
  "scope": "openid profile email",
  "email_verified": true,
  "name": "MCP User",
  "may_act": {
    "sub": "system:serviceaccount:default:agent-sa"
  },
  "preferred_username": "mcp-user",
  "given_name": "MCP",
  "family_name": "User",
  "email": "user@mcp.example.com"
}
```

OBO Token:

```json
{
  "act": {
    "sub": "system:serviceaccount:default:agent-sa",
    "iss": "https://kubernetes.default.svc.cluster.local"
  },
  "exp": 1769450288,
  "iat": 1769363888,
  "iss": "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777",
  "nbf": 1769363888,
  "scope": "openid profile email",
  "sub": "e3349fa1-02c5-4d80-b497-4e7963b20148"
}
```