# Demo: code-openapi-mcp

Demonstrates `toolMode: Code` on an OpenAPI-derived MCP backend.

Instead of exposing 6 separate Petstore tools, the gateway collapses them all
into a single `run_code` tool. The model writes JavaScript; agentgateway
executes it in an embedded QuickJS sandbox with each Petstore operation
bound as an async JS function. The model can call them freely within the
script, filter/join/aggregate in JS, and return only the answer.

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
   npx @modelcontextprotocol/inspector --transport http --server-url http://localhost:3000/code-openapi-mcp/mcp
   ```

2. When the process prints a **Session token** / link containing `MCP_PROXY_AUTH_TOKEN`, open that URL. If the browser opened without the token, open **Configuration** in the sidebar, set **Proxy Session Token** to the value from the terminal, and save.

3. In the connection panel, choose **Streamable HTTP** if the UI offers it; otherwise **HTTP** (the inspector maps that to streamable HTTP for `/mcp` URLs).

4. Set **URL** to `http://localhost:3000/code-openapi-mcp/mcp`, then **Connect**.

5. Under **Tools**, run **List Tools** (expect a single tool: `run_code`).

6. **Call Tool** → choose `run_code`. The inspector shows a **`code`** argument (often a multiline box): paste your JavaScript there only — you do not type the outer `{"code": ...}` wrapper; the UI sends that shape to the server. Use the exact bound function names from the tool description (see the heads-up under **Step 2 — tools/list** below). Example — count available pets:

   ```js
   const pets = await find_pets_by_status_find_pets_by_status({ status: "available" });
   ({ count: pets.length })
   ```

   The last expression in the script is the return value; top-level `await` is allowed.

   If your client only offers a raw JSON editor, use `{"code": "<script with escaped quotes/newlines>"}` instead.

This demo route does not require an `Authorization` header unless you added auth in front of the gateway yourself.

### CLI

With the gateway port-forwarded, transport is inferred from the `/mcp` URL.

**List tools**

```bash
npx @modelcontextprotocol/inspector --cli http://localhost:3000/code-openapi-mcp/mcp --method tools/list
```

**Call `run_code`** (`--tool-arg` is `name=value`; keep the script in one line or use your shell’s quoting rules):

```bash
npx @modelcontextprotocol/inspector --cli http://localhost:3000/code-openapi-mcp/mcp --method tools/call \
  --tool-name run_code \
  --tool-arg 'code=const pets = await find_pets_by_status_find_pets_by_status({ status: "available" }); ({ count: pets.length })'
```

## Calling the MCP endpoint

### Step 1 — initialize

```bash
curl -s -D - -X POST http://localhost:3000/code-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

### Step 2 — tools/list

```bash
SESSION=<paste session id>

curl -s -X POST http://localhost:3000/code-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

Expected: **exactly one tool** named `run_code`. Its description includes the
full JS API surface.

> **Heads-up on JS binding names.** The gateway currently namespaces each
> custom target as `{target}_{target}`, so the JS binding for the YAML target
> `find-pets-by-status` is `find_pets_by_status_find_pets_by_status` (hyphens
> sanitized to underscores). The description in `tools/list` reflects the
> actual callable name — always copy the exact identifier from the description
> rather than inferring it from the YAML target name.

```js
// Finds Pets by status. Returns a list of pets matching the given status.
// type Input = { status: "available" | "pending" | "sold" }
async function find_pets_by_status_find_pets_by_status(input);

// Find pet by ID. Returns a single pet.
// type Input = { petId: number }
async function get_pet_by_id_get_pet_by_id(input);

// Find pets by status, then fetch full details for the first match.
// Demonstrates chained HTTP steps + CEL output composition.
// type Input = { status: "available" | "pending" | "sold" }
async function featured_pet_featured_pet(input);
// ... etc.
```

`featured_pet_*` is the chained custom target from `petstore-custom-backend.yaml`.
From JS it looks like one async call; server-side the gateway runs two chained
HTTP steps and a CEL composition before the result comes back. So a single
`run_code` invocation can combine model-authored JS, server-side CEL pipelines,
and tool calls — all under one MCP request.

### Step 3 — run_code

Send any JavaScript that uses the bound functions. The final expression in the
script becomes the return value. Top-level `await` is available.

```bash
# Count available pets and return a small sample
curl -s -X POST http://localhost:3000/code-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "run_code",
      "arguments": {
        "code": "const pets = await find_pets_by_status_find_pets_by_status({ status: \"available\" });\n({ count: pets.length, sample: pets.slice(0,3).map(p => ({ id: p.id, name: p.name })) })"
      }
    }
  }'
```

```bash
# Fan out in parallel: fetch available AND pending pets, compare counts
curl -s -X POST http://localhost:3000/code-openapi-mcp/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "run_code",
      "arguments": {
        "code": "const fn = find_pets_by_status_find_pets_by_status;\nconst [available, pending] = await Promise.all([\n  fn({ status: \"available\" }),\n  fn({ status: \"pending\" })\n]);\n({ available: available.length, pending: pending.length })"
      }
    }
  }'
```

## Sandbox limits

Code Mode runs in a QuickJS sandbox per `run_code` call:

| Limit | Value |
|-------|-------|
| Memory | 4 MiB |
| Stack | 256 KiB |
| Tool calls | 20 max per script |
| Timeout | 15s (configured in `petstore-code-backend.yaml`) |

Errors (`{ "error": { "message": "..." } }`) are returned instead of thrown so
the MCP client always gets a well-formed tool result.

## How it works

- `petstore-code-backend.yaml` — same `entMcp.targets[]` as the custom-mode
  backend, but with `toolMode: Code` and `codeMode.timeout: 15s` at the top of
  `spec.entMcp`.
- At `tools/list` time the gateway calls all upstream targets, collects their
  declared tools, and returns a single synthesized `run_code` tool. The tool
  description contains a generated JS API reference (type hints + doc comments)
  for every target.
- At `tools/call run_code` time the gateway runs the submitted JS in a per-call
  QuickJS runtime. The bound `async function <toolName>(input)` callbacks invoke
  the gateway's MCP relay, which enforces all policies (RBAC, rate-limits, etc.)
  on each tool invocation — the JS sandbox has no direct network access.
