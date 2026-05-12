# Demo: custom-openapi-mcp

Demonstrates converting an OpenAPI spec into individual MCP tools using
`EnterpriseAgentgatewayBackend` with `entMcp.custom` targets.

Each Petstore3 operation becomes its own MCP tool. The gateway translates
every `tools/call` into an HTTP request to the in-cluster Petstore service —
no hand-written glue code needed.

## Setup

```bash
./setup-openapi-mcp.sh
```

Port-forward the gateway if not already done:

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080
```

## MCP Inspector

The gateway speaks **Streamable HTTP** MCP (same as the `curl` examples: JSON-RPC `POST` with `Accept: application/json, text/event-stream`). Use a current [`@modelcontextprotocol/inspector`](https://www.npmjs.com/package/@modelcontextprotocol/inspector) (upstream expects **Node ≥ 22.7.5**).

### Web UI

1. Start the inspector (optional: pre-fill URL and transport):

   ```bash
   npx @modelcontextprotocol/inspector
   ```

   ```bash
   npx @modelcontextprotocol/inspector --transport http --server-url http://localhost:3000/custom-openapi-mcp/mcp
   ```

2. When the process prints a **Session token** / link containing `MCP_PROXY_AUTH_TOKEN`, open that URL. If the browser opened without the token, open **Configuration** in the sidebar, set **Proxy Session Token** to the value from the terminal, and save.

3. In the connection panel, choose **Streamable HTTP** if the UI offers it; otherwise **HTTP** (the inspector maps that to streamable HTTP for `/mcp` URLs).

4. Set **URL** to `http://localhost:3000/custom-openapi-mcp/mcp`, then **Connect**.

5. Under **Tools**, run **List Tools** (expect six tools). Use **Call Tool** with the exact names from the list (see the naming heads-up below). Example tool names as of this doc: `get-pet-by-id_get-pet-by-id`, `find-pets-by-status_find-pets-by-status`, `get-inventory_get-inventory`.

This demo route does not require an `Authorization` header unless you added auth in front of the gateway yourself.

### CLI (quick smoke)

With the gateway port-forwarded, `tools/list` (transport is inferred from the `/mcp` path):

```bash
npx @modelcontextprotocol/inspector --cli http://localhost:3000/custom-openapi-mcp/mcp --method tools/list
```

Example `tools/call` (arguments are `key=value` pairs):

```bash
npx @modelcontextprotocol/inspector --cli http://localhost:3000/custom-openapi-mcp/mcp --method tools/call \
  --tool-name get-pet-by-id_get-pet-by-id --tool-arg petId=1
```

## Calling the MCP endpoint

### Step 1 — initialize (get a session ID)

```bash
curl -s -D - -X POST http://localhost:3000/custom-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

Copy the `mcp-session-id` header value from the response headers.

### Step 2 — list tools

```bash
SESSION=<paste session id>

curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

Expected: 7 tools — six 1:1 wrappers around individual Petstore operations
plus one hand-written **chained** target (`featured-pet`) that exists to
demonstrate what `custom` is actually for. **Heads-up on naming:** the gateway
currently namespaces each custom target's tool name as `{target}_{target}`
(so the YAML target named `get-pet-by-id` is exposed as
`get-pet-by-id_get-pet-by-id`). Use whatever `tools/list` returns — the names
below assume the current doubled form.

### Step 3 — call a 1:1 tool (one OpenAPI op = one MCP tool)

```bash
# Get the seeded "Doggie" pet (ID 1)
curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get-pet-by-id_get-pet-by-id","arguments":{"petId":1}}}'

# List all available pets
curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"find-pets-by-status_find-pets-by-status","arguments":{"status":"available"}}}'

# Check store inventory
curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get-inventory_get-inventory","arguments":{}}}'
```

### Step 4 — call the chained `featured-pet` tool

This is where `custom` earns its keep — one MCP tool, two server-side HTTP
calls, and a composed result. The target definition (see
`petstore-custom-backend.yaml`):

1. **Step 1 `list`** — `GET /api/v3/pet/findByStatus?status=<input.status>`
2. **Step 2 `detail`** — `GET /api/v3/pet/` + `output.list[0].id` *(chain: step 2's path reads step 1's response body)*
3. **`output:` CEL** — returns
   ```cel
   {
     "requested_status": input.status,
     "total_matches": size(output.list),
     "first_match_summary": { "id": output.list[0].id, "name": output.list[0].name },
     "first_match_details": output.detail
   }
   ```

Call it:

```bash
curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"featured-pet_featured-pet","arguments":{"status":"available"}}}'
```

The MCP client gets one structured object back, but the gateway made two
chained HTTP calls to petstore on its behalf — and the model never had to
juggle intermediate state. That's the part the 1:1 tools above don't show.

## How it works

- `petstore-deployment.yaml` — deploys `swaggerapi/petstore3` in `agentgateway-system`
- `petstore-custom-backend.yaml` — an `EnterpriseAgentgatewayBackend` with
  `entMcp.targets[].custom`:
  - **Six 1:1 targets** generated from the Petstore OpenAPI spec. Each has a
    single HTTP step and `output: output.request` — i.e., a pure HTTP
    pass-through. Generated by `openapi-to-composite` (see Regenerating below).
  - **One hand-written chained target** (`featured-pet`) with two HTTP steps
    where step 2 reads from `output.list[0].id` and the target's `output:` is
    a multi-field CEL expression composing both step responses. This is the
    target that demonstrates what `custom` is actually for.
  - Common to all targets: `inputSchema` (JSON Schema for tool args),
    `steps[].http.backendRef` (points at the in-cluster petstore Service), and
    `path`/`body`/`headers` as CEL expressions over `input.*` / `output.*`.
- `petstore-custom-httproute.yaml` — HTTPRoute wiring `/custom-openapi-mcp/mcp`
  to the backend

## Regenerating the backend YAML

The backend YAML was produced by the `openapi-to-composite` CLI (WIP on
`exp/openapitocustom` in the agentgateway-enterprise repo). To regenerate:

1. Port-forward the in-cluster petstore and fetch its spec:
   ```bash
   kubectl port-forward -n agentgateway-system svc/petstore 8080:8080 &
   curl -s http://localhost:8080/api/v3/openapi.json -o /tmp/petstore-openapi.json
   ```

2. Run the CLI from the agentgateway-enterprise checkout:
   ```bash
   go run ./ent-controller/cmd/openapi-to-composite \
     --name petstore-custom-mcp \
     --namespace agentgateway-system \
     --service-name petstore \
     --service-port 8080 \
     --base-path /api/v3 \
     --operation getPetById \
     --operation findPetsByStatus \
     --operation addPet \
     --operation updatePet \
     --operation getInventory \
     --operation deletePet \
     -o resources/openapi-mcp/petstore-custom-backend.yaml \
     /tmp/petstore-openapi.json
   ```
