# Plan: `custom-openapi-mcp` and `code-openapi-mcp` demos

## Context

Two new features have landed in agentgateway-enterprise that turn an OpenAPI spec into MCP tooling:

1. **`entMcp.custom` targets** (PRs #770, #848) — a CEL-driven pipeline that lets one MCP tool be backed by ordered HTTP and/or MCP steps. Configured declaratively on `EnterpriseAgentgatewayBackend`.
2. **`entMcp.toolMode: Code`** (commit `eb60942e8`) — a per-backend setting that replaces the tool listing with a single `run_code` tool. The model writes JavaScript; agentgateway executes it in an embedded QuickJS sandbox with the upstream tools exposed as `async function <tool>(input)` bindings.
3. **`openapi-to-composite` CLI** (commit `433a1decd`, WIP on `exp/openapitocustom`) — generates `EnterpriseAgentgatewayBackend` YAML with one `custom` target per selected OpenAPI operation.

There is no demo in this directory that exercises any of these. The goal is to add two demos — one for the OpenAPI→custom flow, one for OpenAPI→custom+code-mode — targeting the **shared cluster** stood up by `setup-gateway.sh` (not isolated kind clusters). Demos follow the existing convention: a top-level `setup-*.sh` script plus YAML under `resources/<topic>/`.

## Design decisions (locked in via Q&A)

- **OpenAPI backend**: Swagger's reference Petstore3 (`docker.io/swaggerapi/petstore3`) deployed in-cluster. Self-contained, OpenAPI 3.0, predictable.
- **YAML provenance**: Pre-generate the `EnterpriseAgentgatewayBackend` YAML offline with the WIP `openapi-to-composite` CLI from the agentgateway-enterprise repo, then hand-tidy and check it in. Document the CLI command used in the demo README so it is reproducible.
- **Auth**: None on these two demos. Existing demos (`mcp-oidc.yaml`, `jwt-secure.yaml`) already cover auth.
- **Validation**: Extend `validate/run-tests.sh` with new cases (tests 24+) covering MCP `initialize`, `tools/list`, a `tools/call` against the custom-mode route, and a `run_code` call against the code-mode route.
- **Operations selected from Petstore**: a small, varied set that exercises path/query/body params — `getPetById` (path), `findPetsByStatus` (query), `addPet` (POST body), `updatePet` (PUT body), `getInventory` (no params), `deletePet` (DELETE path). Six operations is enough to make the JS `run_code` API surface meaningful without bloating the description.

## Files to create / modify

### Shared (used by both demos)

- `resources/openapi-mcp/petstore-deployment.yaml` **(new)** — `Namespace` `petstore`, `Deployment` running `docker.io/swaggerapi/petstore3:unstable` on port 8080, `Service` `petstore.petstore.svc.cluster.local:8080`. (Container exposes the OpenAPI spec at `/api/v3/openapi.json`.)

### Demo 1 — `custom-openapi-mcp`

- `resources/openapi-mcp/petstore-custom-backend.yaml` **(new, pre-generated)** — single `EnterpriseAgentgatewayBackend` named `petstore-custom-mcp` in namespace `petstore`, with `entMcp.targets[]` containing one `custom:` target per selected operation. Each target has:
  - `description` from the OpenAPI summary
  - `inputSchema` derived from path/query/body params
  - one `steps[].http` referencing the in-cluster `petstore` Service via `backendRef` (port 8080)
  - `path`, `headers`, `body` as CEL expressions built from `input.*`
  - `output: output.request`
- `resources/openapi-mcp/petstore-custom-httproute.yaml` **(new)** — `HTTPRoute` attached to the existing gateway in `agentgateway-system`, path `/custom-openapi-mcp` → `petstore-custom-mcp` backend.
- `setup-custom-openapi-mcp.sh` **(new, top-level)** — sources `.env`, `kubectl apply -f` the three files above, prints the MCP endpoint URL.
- `resources/openapi-mcp/README-custom.md` **(new)** — short doc with: the exact `openapi-to-composite` command used to (re)generate `petstore-custom-backend.yaml`, the curl/MCP-inspector commands to call `tools/list` and `tools/call`, expected output shapes.

### Demo 2 — `code-openapi-mcp`

- `resources/openapi-mcp/petstore-code-backend.yaml` **(new)** — copy of `petstore-custom-backend.yaml` renamed to `petstore-code-mcp`, with these additions at the top of `spec.entMcp`:
  ```yaml
  toolMode: Code
  codeMode:
    timeout: 15s
  ```
  The CRD test data at `ent-controller/internal/plugins/agentgateway/testdata/backends/code-mode-mcp.yaml` (in the enterprise repo) confirms this shape.
- `resources/openapi-mcp/petstore-code-httproute.yaml` **(new)** — `HTTPRoute` path `/code-openapi-mcp` → `petstore-code-mcp` backend.
- `setup-code-openapi-mcp.sh` **(new, top-level)** — sources `.env`, applies the two files above (the shared petstore deployment is applied idempotently so this script works standalone).
- `resources/openapi-mcp/README-code.md` **(new)** — README explaining what `run_code` looks like (one tool, JS API in the description), plus a worked example script that calls `findPetsByStatus({ status: "available" })`, filters by category, and returns a small summary — exercising the "do work in JS, return only the answer" pattern from the synthesized description.

### Top-level docs

- `README.md` **(edit)** — add two bullets to the demos list pointing to the new setup scripts.

### Validation

- `validate/run-tests.sh` **(edit)** — append:
  - Test 24 (`custom-openapi-mcp`): MCP `initialize` + `tools/list` against `http://<gw>/custom-openapi-mcp/mcp`. Assert a tool named (or section-named) `getpetbyid` (or whatever the generator emits) appears. Then `tools/call` `getPetById` with `{ "petId": 1 }` and assert HTTP 200 + non-error result.
  - Test 25 (`code-openapi-mcp`): MCP `initialize` + `tools/list` and assert exactly one tool named `run_code` is returned and its description contains `async function findPetsByStatus`. Then `tools/call` `run_code` with a short JS body that returns `(await findPetsByStatus({ status: "available" })).length` and assert the structured `success` field is a number.
  - Slot the new cases at the bottom alongside the existing MCP search tests (21–23) so the ordering convention is preserved.

## Concrete generation step (one-time, off-checkin)

Run from the agentgateway-enterprise checkout on `exp/openapitocustom`:

```
go run ./ent-controller/cmd/openapi-to-composite \
  --name petstore-custom-mcp \
  --namespace petstore \
  --service-name petstore \
  --service-port 8080 \
  --base-path /api/v3 \
  --operation getPetById \
  --operation findPetsByStatus \
  --operation addPet \
  --operation updatePet \
  --operation getInventory \
  --operation deletePet \
  -o /Users/ceposta/dev/code/agw-demos/enterprise/resources/openapi-mcp/petstore-custom-backend.yaml \
  /tmp/petstore-openapi.json
```

(`/tmp/petstore-openapi.json` is fetched once via `curl http://<port-forward>/api/v3/openapi.json`.) The exact command is captured in `README-custom.md` so the file can be regenerated whenever the CLI stabilises or the OpenAPI spec changes.

`petstore-code-backend.yaml` is **not** regenerated independently — it's a copy of `petstore-custom-backend.yaml` with the `toolMode: Code` + `codeMode.timeout` block added and the resource `metadata.name` changed. A trailing comment in the file should note this so future maintainers don't try to regenerate it directly.

## Verification (end-to-end)

After `./setup-gateway.sh` has already provisioned the shared cluster:

1. `./setup-custom-openapi-mcp.sh` — should report `Deployment petstore created`, EAB accepted, HTTPRoute attached. `kubectl -n petstore wait deploy/petstore --for=condition=Available` should succeed.
2. Port-forward the gateway and call MCP:
   ```
   curl -s -X POST http://localhost:8080/custom-openapi-mcp/mcp \
     -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
   Expect a tool list with ~6 entries.
3. Call `getPetById` via `tools/call` with `{ "petId": 1 }` and confirm the response includes the pet's JSON (Petstore seeds some pets at startup).
4. `./setup-code-openapi-mcp.sh` — same wiring, on `/code-openapi-mcp`.
5. `tools/list` against `/code-openapi-mcp/mcp` returns **one** tool named `run_code`; its description contains the JS API for all six bound functions.
6. `tools/call` `run_code` with body:
   ```js
   const pets = await findPetsByStatus({ status: "available" });
   ({ count: pets.length, sample: pets.slice(0,3).map(p => ({ id: p.id, name: p.name })) })
   ```
   Expect a `success` payload with `count` and a `sample` array.
7. `./validate/run-tests.sh` — tests 1–23 still pass, new tests 24–25 pass.

## Open / deferred

- The `openapi-to-composite` CLI is on the `exp/openapitocustom` branch and marked WIP. If its output schema changes before merge, `petstore-custom-backend.yaml` (and the code-mode sibling) must be regenerated. Tracked in the README, not blocking.
- The Code Mode JS sandbox enforces a 20-tool-call cap and a 4 MiB memory limit per `run_code` call — both worth a note in `README-code.md` so demo viewers understand the trade-off vs. Standard mode.
