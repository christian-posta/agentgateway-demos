# Demo: secure-openapi-mcp

Demonstrates **MCP Auth** in front of the petstore custom MCP backend, using
the newer `traffic.jwtAuthentication.mcp` policy field. This single policy:

- Validates incoming JWTs in `Strict` mode against an Auth0 tenant.
- Serves the **MCP OAuth discovery endpoints**
  (`/.well-known/oauth-protected-resource/...` and
  `/.well-known/oauth-authorization-server/...`) so MCP clients can complete
  the OAuth dance automatically.
- Layers per-tool authorization (`backend.mcp.authorization`) on top of the
  validated JWT — reads are open to any authenticated caller; mutations
  require the `petstore:write` Auth0 permission.

The backend itself (`petstore-custom-mcp`) is the same as **custom-openapi-mcp**;
this demo only adds the secured route and policy (both are applied by
`setup-openapi-mcp.sh`).

## Why `traffic.jwtAuthentication.mcp`?

There are two ways to get OAuth metadata served by agentgateway:

| Field | Status | Where auth runs |
|-------|--------|-----------------|
| `backend.mcp.authentication` | Older / deprecated | At the backend level |
| `traffic.jwtAuthentication.mcp` | **Recommended** | At the traffic phase, before routing |

The new shape ensures auth runs early in the request pipeline and unifies JWT
validation with MCP discovery in a single block.

Constraints (enforced by CRD validation):
- `jwtAuthentication.mcp` requires **exactly one** provider.
- `jwtAuthentication.mcp` requires **mode: Strict**.
- `traffic.jwtAuthentication` cannot be combined with
  `backend.mcp.authentication` in the same policy.

## Setup

```bash
./setup-openapi-mcp.sh
```

Port-forward the gateway if not already done:

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080
```

You also need an Auth0 tenant. The example points at `ceposta-solo.auth0.com`
(the same tenant `resources/mcp/public-oauth.yaml` uses). To use your own
tenant, edit `resources/openapi-mcp/petstore-secure-httproute.yaml`:

- `issuer:` — `https://<your-tenant>.auth0.com/` (trailing slash matters).
- `audiences:` — the **identifier** of your Auth0 API (must match the `aud`
  claim issued in your access tokens).
- `petstore-auth0-jwks` backend `host:` — `<your-tenant>.auth0.com`.
- `resourceMetadata.resource` / `authorizationServers` — your gateway's
  externally-reachable URL (ngrok / LB / DNS) that Auth0 will redirect back
  to during the OAuth flow.

In the Auth0 dashboard:
- Create an **API** with the identifier you put under `audiences:`.
- Enable **RBAC** and **Add Permissions in the Access Token** on that API.
- Define a permission named `petstore:write` and grant it to whichever users
  / clients should be able to call the mutating tools.

## Verify auth is enforced

### Unauthenticated → 401

```bash
curl -i -X POST http://localhost:3000/secure-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

Expect `HTTP/1.1 401 Unauthorized` and a `WWW-Authenticate` header pointing at
the resource metadata URL — that's how MCP clients discover the IdP.

### Discovery endpoints (no auth required)

```bash
curl -s http://localhost:3000/.well-known/oauth-protected-resource/secure-openapi-mcp/mcp | jq .
curl -s http://localhost:3000/.well-known/oauth-authorization-server/secure-openapi-mcp/mcp | jq .
```

The protected-resource document should list your Auth0 tenant (via the
gateway's `/secure-openapi-mcp/mcp` URL) under `authorization_servers` and
the gateway URL as `resource`.

### Authenticated call

Grab an Auth0 token via client-credentials (replace with your client ID,
secret, and API audience):

```bash
TOKEN=$(curl -s -X POST \
  https://ceposta-solo.auth0.com/oauth/token \
  -H 'content-type: application/json' \
  -d '{
        "client_id": "'$AUTH0_CLIENT_ID'",
        "client_secret": "'$AUTH0_CLIENT_SECRET'",
        "audience": "https://ceposta-agw.ngrok.io/secure-openapi-mcp/mcp",
        "grant_type": "client_credentials"
      }' | jq -r .access_token)
```

Other flows work too — e.g. `./get-auth0-token.sh` (used by the elicitation
demo) or any browser-based authorization-code flow that ends up with an
access token whose `aud` matches the policy's `audiences`.

Initialize + grab session:

```bash
curl -s -D - -X POST http://localhost:3000/secure-openapi-mcp/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

Copy the `mcp-session-id` header, then call a read tool — works for any
authenticated user:

```bash
SESSION=<paste session id>

curl -s -X POST http://localhost:3000/secure-openapi-mcp/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get-pet-by-id_get-pet-by-id","arguments":{"petId":1}}}'
```

Try a write tool without the `petstore:write` permission — the request is
authenticated but the MCP authorization layer rejects it:

```bash
curl -s -X POST http://localhost:3000/secure-openapi-mcp/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete-pet_delete-pet","arguments":{"petId":1}}}'
```

Grant `petstore:write` on the Auth0 API to your user / client (Auth0 dashboard
→ APIs → your API → Permissions / Machine-to-Machine Applications), re-issue
the token, and the same call succeeds.

## MCP Inspector / VS Code

Because the `.well-known` endpoints are served, MCP clients with OAuth support
discover the IdP automatically:

```bash
npx @modelcontextprotocol/inspector --transport http --server-url http://localhost:3000/secure-openapi-mcp/mcp
```

When prompted, sign in through Auth0. The inspector caches the bearer token
and attaches it to every MCP request thereafter.

## Files

- `petstore-secure-httproute.yaml` — `HTTPRoute` for `/secure-openapi-mcp/mcp`
  and the two `.well-known` paths, plus the Keycloak JWKS backend and the
  `EnterpriseAgentgatewayPolicy` with `traffic.jwtAuthentication.mcp` and
  `backend.mcp.authorization`.
- Reuses `petstore-deployment.yaml` and `petstore-custom-backend.yaml`
  unchanged.

## Reference

- API doc: <https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/policies/#spec.traffic.jwtAuthentication.mcp>
- Existing JWT example: `resources/mcp/jwt-secure.yaml` (older style — uses
  `traffic.jwtAuthentication` without `.mcp`)
- Existing OAuth example: `resources/mcp/mcp-oidc.yaml` (older style — uses
  `backend.mcp.authentication`)
