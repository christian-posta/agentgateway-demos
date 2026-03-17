# Microsoft Entra ID (Azure AD) On-Behalf-Of (OBO) with Agentgateway

This guide configures Enterprise Agentgateway to perform **Microsoft Entra ID On-Behalf-Of (OBO)** token exchange: the gateway accepts a user’s access token (for the middle-tier API), exchanges it with Entra for a token for a downstream API, and forwards requests to the backend with that exchanged token.

**References:**

- [Microsoft identity platform and OAuth 2.0 On-Behalf-Of flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [RFC 8693 Token Exchange](https://www.rfc-editor.org/rfc/rfc8693)

**Example IDs** (for copy-paste when filling `.env`; use your own tenant/apps in production):

- Tenant: `5e7d8166-7876-4755-a1a4-b476d4a344f6`
- Middle-tier client ID: `ec791040-80f8-4129-bf34-96a0e0672c96` (token `aud` = `api://ec791040-80f8-4129-bf34-96a0e0672c96`)
- Downstream scope: `api://9beda151-9370-42f2-a2f7-17933c5c5a7c/.default`

---

## Overview

1. **Client** sends a request to the gateway with an **Entra user access token** (audience = your middle-tier API / gateway’s app registration).
2. **Gateway** validates the JWT using Entra’s JWKS and (when the route has token exchange enabled) calls its internal **STS (token exchange)** service with `subject_token` and `resource` (backend identifier).
3. **STS** looks up the **Entra OBO** provider for that `resource`, then calls Entra’s token endpoint with:
  - `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`
  - `assertion=<incoming token>`
  - `requested_token_use=on_behalf_of`
  - `client_id`, `client_secret`, `scope` from the policy’s Entra config.
4. **Entra** returns an access token for the **downstream API** (the `scope` you configured).
5. **Gateway** sends the request to the **backend** with `Authorization: Bearer <exchanged token>`.

---

## Prerequisites

- **Local:** Docker, [kind](https://kind.sigs.k8s.io/), kubectl, helm.
- **Entra (Azure AD):**
  - **Middle-tier app** (the API that clients call; gateway validates tokens for this app).
  - **Downstream API** (the service behind the gateway that needs its own token).
  - Middle-tier app has a **client secret** and is configured for OBO (API permissions for the downstream API, e.g. `api://<downstream-app-id>/.default`).
  - Optional: [knownClientApplications](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow#default-and-combined-consent) for combined consent.

Set these in `enterprise/.env` (copy from `example.env`):


| Variable                     | Description                                                   | Example                                               |
| ---------------------------- | ------------------------------------------------------------- | ----------------------------------------------------- |
| `AGENTGATEWAY_LICENSE`       | Enterprise Agentgateway license key                           | (your key)                                            |
| `ENTERPRISE_AGW_VERSION`     | Chart version                                                 | `2.2.0`                                               |
| `ENTRA_TENANT_ID`            | Entra tenant ID (UUID)                                        | `5e7d8166-7876-4755-a1a4-b476d4a344f6`                |
| `ENTRA_MIDDLETIER_CLIENT_ID` | Middle-tier app (client) ID — token’s `aud` is `api://<this>` | `ec791040-80f8-4129-bf34-96a0e0672c96`                |
| `ENTRA_DOWNSTREAM_SCOPE`     | Downstream API scope                                          | `api://9beda151-9370-42f2-a2f7-17933c5c5a7c/.default` |
| `ENTRA_OBO_CLIENT_SECRET`    | Middle-tier app’s client secret (value, not ID)               | (never commit; set in .env only)                      |


---

## Quick start: one script

From the **enterprise** directory:

```bash
cd enterprise
cp example.env .env
# Edit .env: set AGENTGATEWAY_LICENSE, ENTERPRISE_AGW_VERSION, and all ENTRA_* variables above.

./setup-msft-obo.sh
```

This will:

1. Create a kind cluster named **agw-msft-obo** (unless `CREATE_KIND_CLUSTER=0`).
2. Create namespace `agentgateway-system`.
3. Install Gateway API (v1.5.0) and Enterprise Agentgateway CRDs + controller with **Entra OBO** token exchange (validators pointing to Entra JWKS; no elicitation).
4. Create the Entra client secret and apply gateway params, gateway, route, backends (including JWKS + demo httpbin), and JWT + OBO policies.

To use an **existing cluster** and skip kind:

```bash
CREATE_KIND_CLUSTER=0 ./setup-msft-obo.sh
```

---

## What the script installs

- **Gateway API** — standard-install.
- **Enterprise Agentgateway** — CRDs + controller; Helm values set for Entra OBO:
  - `tokenExchange.enabled: true`, issuer and validators (subject/api → Entra JWKS URL), actor validator k8s, no elicitation secret.
- **Parameters** — `EnterpriseAgentgatewayParameters` `**agentgateway-params-msft-obo`** (dedicated name to avoid overwriting the shared `agentgateway-params` used by `setup-gateway.sh` and `resources/obo/`) with `STS_URI` = `.../oauth2/token` and `STS_AUTH_TOKEN`.
- **Gateway** — `token-exchange-gateway` with params ref, listener 8080.
- **Backends** — `entra-jwks` (login.microsoftonline.com:443) and `obo-demo-backend` (in-cluster httpbin).
- **HTTPRoute** — path prefix `**/**` → `obo-demo-backend` (all paths route to httpbin; no path prefix).
- **Policies** — JWT auth (Entra issuer/audience, JWKS via `entra-jwks`) and Entra OBO token exchange on `obo-demo-backend`.

---

## Testing

### 1. Obtain a user token (middle-tier audience)

Log in and get an access token for your **middle-tier** app:

```bash
# Log in (resource = api://<middle-tier-client-id>)
az login --tenant "5e7d8166-7876-4755-a1a4-b476d4a344f6" --scope "api://ec791040-80f8-4129-bf34-96a0e0672c96/.default"

# Get token and set USER_TOKEN
export USER_TOKEN=$(az account get-access-token \
  --tenant "5e7d8166-7876-4755-a1a4-b476d4a344f6" \
  --resource "api://ec791040-80f8-4129-bf34-96a0e0672c96" \
  --query accessToken -o tsv)
```

Alternatively use MSAL / an app that signs in the user and requests a token with scope for the middle-tier API. The token’s `aud` should match the middle-tier app (e.g. `api://ec791040-80f8-4129-bf34-96a0e0672c96`).

### 2. Port-forward and call the gateway

```bash
# Port-forward the gateway (gateway pod listens on 8080)
AGW=$(kubectl -n agentgateway-system get pods -l gateway.networking.k8s.io/gateway-name=token-exchange-gateway -o jsonpath='{.items[0].metadata.name}')
kubectl -n agentgateway-system port-forward "$AGW" 8080:8080

export GATEWAY_URL="http://localhost:8080"

# httpbin: use /headers to see request headers (including the exchanged Authorization token)
curl -i -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY_URL/headers"
```

- **200** and JSON with request headers (e.g. `"Authorization": "Bearer <exchanged-token>"`): JWT validation and OBO succeeded; backend received the exchanged token.
- **401**: Check token validity, issuer (`https://sts.windows.net/{tenant}/`), audience (middle-tier app), and that the JWKS backend can reach `login.microsoftonline.com`.
- **4xx from STS**: Check controller logs for token exchange errors; ensure token `aud` matches policy `clientId` and middle-tier app has consent for the downstream `scope`.

### 3. Verify the backend receives the exchanged token

For Entra OBO, the backend receives a token from Entra for the requested `scope` (downstream API). You can enable request logging in gateway parameters (e.g. `logging.fields.add.request.headers`) and inspect the `Authorization` header sent to the backend.

---

## Flow summary

1. Client calls gateway with `Authorization: Bearer <user-entra-token>` (token for middle-tier API).
2. JWT policy validates the token with Entra JWKS (issuer `https://sts.windows.net/{tenant}/`, audience = middle-tier app).
3. Proxy forwards to backend; token exchange is triggered for the backend’s resource key (`agentgateway-system/obo-demo-backend`). Request path is forwarded as-is (no path prefix).
4. Proxy POSTs to STS `/oauth2/token` with `subject_token=<user-entra-token>` and `resource=agentgateway-system/obo-demo-backend`.
5. STS finds the Entra provider for that resource, validates `subject_token`, then calls Entra OBO and gets a token for `scope` (downstream API).
6. STS returns that token to the proxy; proxy sends the request to the backend with `Authorization: Bearer <exchanged-token>`.

---

## Troubleshooting


| Symptom                                     | What to check                                                                                                                                                                                                                                          |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 401 on request                              | Token expiry, issuer (`https://sts.windows.net/{tenant}/`), audience (middle-tier app). JWKS backend for JWT policy must be reachable (`entra-jwks` → `login.microsoftonline.com:443`).                                                                |
| Token exchange fails (e.g. invalid_grant)   | Entra error in controller logs. Typical causes: `aud` of incoming token ≠ `clientId` in policy; missing consent for `scope`; wrong tenant/client/secret.                                                                                               |
| No token exchange (backend gets user token) | Policy must target the **same** backend (and namespace) as the route’s `backendRef`. Resource key is `{namespace}/{backend-name}`. Ensure `backend.tokenExchange.entra` and `clientSecretRef` are set and the Secret exists in the policy’s namespace. |
| STS_URI wrong                               | Use full URL including path: `http://<controller-service>.<namespace>.svc.cluster.local:7777/oauth2/token`. Path is `/oauth2/token`, not `/oauth2/token/exchange`.                                                                                     |
| **Only control plane, no gateway proxy**    | See [No data plane (proxy) running](#no-data-plane-proxy-running) below.                                                                                                                                                                               |


### No data plane (proxy) running

You see the Enterprise Agentgateway controller (control plane) but no proxy/data plane pod for `token-exchange-gateway`. The proxy is created by the controller when it reconciles your **Gateway** resource. Check the following:

1. **Gateway exists and is programmed**
  ```bash
   kubectl get gateway -n agentgateway-system
   kubectl describe gateway token-exchange-gateway -n agentgateway-system
  ```
   In `Status` look for conditions like `Accepted` / `Programmed`. If the Gateway is not accepted, check `GatewayClass` and controller logs.
2. **GatewayClass exists and has a controller**
  ```bash
   kubectl get gatewayclass
  ```
   You should see `enterprise-agentgateway` with a controller name.
3. **Parameters ref exists**
  The Gateway references `agentgateway-params-msft-obo`. Confirm it exists:
4. **Find the proxy deployment and pods**
  The data plane is a **separate** Deployment created by the controller when it programs the Gateway (controller and proxy are not the same deployment). List deployments and pods:
   The controller is `enterprise-agentgateway`. The proxy deployment name and labels are defined by the Enterprise Agentgateway chart—see the chart documentation or controller logs to see how the programmed Gateway’s proxy is named and where it is created. If no proxy deployment appears despite the Gateway being Programmed, check controller logs (step 5) for errors or for the name/namespace of the created deployment.
5. **Controller logs**
  If the Gateway is not programmed or no deployment is created, check the controller logs for errors (e.g. params resolution, admission):
6. **Port-forward once the proxy is running**
  When you have the proxy deployment name (from step 4), port-forward it (listener is 8080). If the deployment is named `token-exchange-gateway`:
   Or by pod label if your chart uses it:

---

## Coexistence with `enterprise/resources/obo/`

This guide is intended for a **dedicated cluster** (e.g. kind `agw-msft-obo`) focused on Entra OBO. If you ever run both demos in the same cluster, this one is designed so it does **not** collide with the existing Keycloak/Auth0 agent OBO demo in `enterprise/resources/obo/`:


| Resource       | `resources/obo/`                                               | `resources/msft-obo/`                                                            |
| -------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Gateway**    | `agentgateway` (from setup/gateway.yaml)                       | `token-exchange-gateway`                                                         |
| **Parameters** | Uses shared `agentgateway-params` (from setup/supporting.yaml) | `**agentgateway-params-msft-obo`** (dedicated; does not overwrite shared params) |
| **Path**       | `/obo`, `/obo/agent`                                           | **/** (all paths)                                                                |
| **Backends**   | Services `demo-agent-ui`, `agent-obo` (default ns)             | `obo-demo-backend`, `entra-jwks` (agentgateway-system)                           |


You can run both demos in the same cluster: the Keycloak OBO UI and agent use the main `agentgateway` and path `/obo`; the Entra OBO demo uses `token-exchange-gateway` with no path prefix (all paths to httpbin). Port-forward to the appropriate gateway pod depending on which you are testing.

---

## Manual steps (without the script)

If you prefer to run steps by hand:

1. Create cluster: `kind create cluster --name agw-msft-obo`
2. In `enterprise/`: `source .env`, then create namespace, apply Gateway API, install CRDs and controller with Entra OBO Helm values (see `setup-msft-obo.sh`).
3. Create secret: `kubectl create secret generic entra-obo-client-secret -n agentgateway-system --from-literal=client_secret="$ENTRA_OBO_CLIENT_SECRET"`
4. Apply manifests in order: `gateway-params.yaml` (creates `agentgateway-params-msft-obo`), `entra-jwks-backend.yaml`, `gateway-and-route.yaml`. For `jwt-auth-policy.yaml` and `entra-obo-policy.yaml`, substitute `ENTRA_TENANT_ID`, `ENTRA_MIDDLETIER_CLIENT_ID`, `ENTRA_DOWNSTREAM_SCOPE` (e.g. `envsubst < jwt-auth-policy.yaml | kubectl apply -f -`). Use the gateway root when testing (e.g. `$GATEWAY_URL/headers`; not `/obo`, which is used by `resources/obo/`).

---

## API note

For OBO you use the dedicated **Entra** policy (`EnterpriseAgentgatewayPolicy.spec.backend.tokenExchange.entra`) and a Secret for the client secret. No generic `tokenExchangeProvider` or token-exchange secret is required. The STS path is `**/oauth2/token`**, not `/oauth2/token/exchange`.