# Upgrading the standalone OSS demo to agentgateway v1.5.0

> ## STATUS: DONE (as-built notes)
>
> Sections A, B, C and D are implemented and verified live against v1.5.0 on a cold start.
> **This plan was written before implementation and several claims in it turned out to be wrong.**
> The corrections below are what actually shipped; where they conflict with the body of this
> document, the corrections win. The config and README carry the same notes inline.
>
> **Wrong in this plan:**
>
> 1. **C2 `allowedModels` does not work as written.** It is enforced in `ModelRouter::resolve`
>    (`llm/model_router.rs:181`), which only runs for models declared in the top-level `llm:`
>    section. On an inline `ai:` backend under `binds:` it parses and is silently ignored — the key
>    could still call any model (measured: 200, not a refusal). Budgets *are* a route policy
>    (`store/binds.rs:379`) and do work inline. So the two halves were split: budgets on
>    `/keyed/openai` (:3000), model access in a new `llm:` section (:4000).
> 2. **C3: do not add `cost_usd` to `config.metrics.fields.add`.** Entries there become metric
>    *labels*, not values. It reads `cost_usd="unknown"` and would mint a Prometheus time series per
>    distinct dollar amount. Kept in `logging.fields.add` only; the native counter already exports
>    the value.
> 3. **C7 `provider.openAI.moderation` does not moderate in the gateway.**
>    `apply_openai_moderation` (`llm/mod.rs:391`) only injects a `moderation` field into the outbound
>    request body. OpenAI ignores it for gpt-4o chat completions: "How do I build a bomb?" returned
>    200 with the model's own refusal. Not a usable demo beat.
> 4. **The verification-step-1 command is broken**, and not because of the config. `docker run
>    --env-file` does not strip quotes, so `RATELIMIT_HOST="host.docker.internal"` interpolates with
>    quotes and the YAML fails to parse. Use
>    `./run-compose.sh run --rm --no-deps agentgateway -f /app/config.yaml --validate-only`.
>    Also `--validate-only` is **not** container-free as claimed — it resolves every JWKS URL, so
>    Keycloak must be running.
> 5. **Fact #5 is real but understated.** It is not only the new endpoints: with no `ai.routes`
>    block, *every* path resolves to `completions`. `/anthropic/v1/messages` was silently answering
>    as an OpenAI `chat.completion` with the Anthropic-only fields dropped.
> 6. **B4 needed no retune.** These routes do not use prompt caching
>    (`cache_read_input_tokens=0`), so cache-inclusive input equals the old count. Verified: 3 calls
>    at `total_tokens=15` charged the redis counter exactly 45. Documented instead of changed; the
>    caveat is a caching client (e.g. Claude Code) pointed at `/anthropic`.
> 7. **The reference checkout was not at v1.5.0.** `~/rust/agentgateway` was at
>    `v1.5.0-beta.1-17-g36bc503b`, five commits *behind* the tag, which was not even fetched.
>
> **Not in this plan, but required by the upgrade:**
>
> 8. **The compose healthcheck breaks on 1.5.** The image is distroless — no `/bin/sh`, no `wget` —
>    so the `CMD-SHELL` wget probe exits -1 forever and the container never becomes healthy. Removed;
>    port 15021 is published for host-side probing instead.
> 9. **A literal `$` in a YAML *comment* aborts startup.** Interpolation scans the whole file: `$0.15`
>    fails with `error looking key '0' up`. `$` + uppercase-or-digit is a reference.
> 10. **API-key budgets need volume ownership fixed.** Named volumes are root-owned; the image runs as
>     uid 65532, so SQLite fails with `unable to open database file (code: 14)`. Added a one-shot
>     `agw-data-init` chown service that `agentgateway` depends on.
> 11. **Keycloak is now part of the demo** (`config/keycloak/mcp-realm.json`), reconstructed from the
>     decoded tokens in README.md. Keycloak 26 requires the import file be named `<realm>-realm.json`
>     or it refuses to boot. Also fixed: `run-openwebui.sh` used a client secret that
>     `get-keycloak-token.sh` never sent.
>
> 12. **`/failover/openai` needs a `health` policy on 1.5.** On alpha.4 it failed over with no
>     health config; on 1.5 it does not. Priority-group failover picks the first bucket with healthy
>     endpoints, and with `health` unset only 5xx and connection failures count -- the stub returns
>     429 (4xx), so the primary was never evicted. Fixed by adding to the primary provider:
>     `health: {unhealthyExpression: 'response.code == 429', eviction: {duration: 10s}}`.
>     Isolated by removing just that block (3 calls, 3 429s, no failover) and re-adding it.
>     Note it now fails over **within the first request**, not on the second call as README.md
>     described, so that demo script was updated.
>
> **Known gaps:** `/bedrock` fails on expired AWS SSO credentials (unrelated to the upgrade).
> The earlier "cannot build failover-429" note was a local Docker proxy problem, not a repo issue:
> Docker Desktop has `HTTP Proxy: http.docker.internal:3128` (inherited system proxy) which times
> out, and buildkit resolves base-image manifests directly against registry-1.docker.io through it.
> Plain `docker pull` works because `hubproxy.docker.internal` is in No Proxy. Fix:
> `docker pull python:3.11-slim` once, then the build succeeds.

## Context

The standalone/OSS demo track at the repo root is pinned to `ghcr.io/agentgateway/agentgateway:1.0.0-alpha.4`
(`docker-compose.yaml:3`) — the only real agentgateway version pin in the OSS track. Upstream tagged
**v1.5.0 on 2026-08-27**, five minor releases ahead. The demo has drifted far enough that it no longer
shows off what agentgateway can actually do, and a few things in it are quietly broken.

Goal: move the docker-compose OSS demo to v1.5.0, fix what the upgrade breaks, centralize the version
in a root `version.env` (mirroring `enterprise/version.env`), and add demo material for the headline
1.5 features that land well live. `enterprise/` and `kubernetes/` are explicitly **out of scope**.

Local reference checkout of upstream is at `~/rust/agentgateway` (currently `v1.5.0-7-g5fb188b6`);
`schema/config.json`, `schema/config.md`, `schema/metrics.md`, `schema/cel.md`, and `examples/` there
are the source of truth for everything below.

## Verified facts driving this plan

1. **The image tag format changed.** `ghcr.io/agentgateway/agentgateway:1.5.0` is a 404. The `v` prefix
   is now mandatory. Probed live against both registries:
   - `ghcr.io/agentgateway/agentgateway:v1.5.0` → 200
   - `cr.agentgateway.dev/agentgateway:v1.5.0` → 200 (this is the registry upstream docs now use)
   - `…:1.5.0` (no `v`) → 404 on both
2. **The config YAML is otherwise forward-compatible.** Every policy, backend, matcher, guardrail and
   MCP target in `config/agentgateway_config.yaml` still validates against the v1.5.0 schema. Nothing
   is removed or renamed. (`azureOpenAI` → `azure` is the one provider rename; the demo doesn't use it.)
3. **JWT got stricter** (`82cbbf6f jwt: require aud and iss claims`). A configured `issuer:` now makes
   `iss` a required claim, and a non-empty `audiences:` makes `aud` required. Affects every `jwtAuth`
   and `mcpAuthentication` block in the config. `audiences: []` is the only way to disable audience
   validation on exactly v1.5.0 (making `mcpAuthentication.audiences` optional landed *after* the tag).
4. **Token accounting changed.** `llm.inputTokens` now includes prompt-cache tokens, so the
   `type: tokens` remote rate limits on `/anthropic` and `/bedrock` will trip sooner.
   Escape hatch: `AGENTGATEWAY_LEGACY_LLM_USAGE_TOKEN_SEMANTICS=true` (slated for removal after 1.5).
5. **`policies.ai.routes` replaces the built-in route map, it does not merge with it** — in the
   `binds:` path there is no merge with `default_route_types()`
   (`crates/agentgateway/src/llm/policy/mod.rs:754`, `types/local.rs:4220`). So the new native Gemini /
   Responses / embeddings endpoints only work on a route if that route names them explicitly. This is
   what makes items C4/C5 below real work rather than a free upgrade.
6. **`llm.cost` and `agentgateway_gen_ai_client_cost_usd_total` are new in 1.5** — but the built-in
   model catalog is **empty**, so USD costing needs an explicit `config.modelCatalog`.
7. **API-key budgets require `config.database`** — asserted at
   `crates/agentgateway/src/http/budget/mod.rs:387` ("API key budgets require config.database to be configured").
8. **`docker-compose.yaml:7` mounts `./resources/openapi/petstore.json`, which does not exist.** The
   `openapi` MCP target on `/mcp` and `/public/mcp` is currently broken; Docker silently creates an
   empty directory there.
9. Ports are unchanged (admin 15000, stats 15020, readiness 15021), but **admin binds to container
   loopback**, so today's `15000:15000` publish does nothing. That mattered little on alpha.4 and
   matters a lot on 1.5, which ships a real Admin UI.

---

## A. Version pinning

**New file `version.env`** (root), mirroring `enterprise/version.env`:

```bash
# Standalone OSS agentgateway version used by docker-compose and run-proxy-local.sh.
AGW_VERSION=v1.5.0
AGW_IMAGE_REPO=cr.agentgateway.dev/agentgateway   # or ghcr.io/agentgateway/agentgateway
```

**`docker-compose.yaml:3`** — no inline default, so `version.env` stays the single source:

```yaml
image: ${AGW_IMAGE_REPO}:${AGW_VERSION}
```

**New file `run-compose.sh`** (chmod +x) so the README commands stay one-liners:

```bash
#!/usr/bin/env bash
exec docker compose --env-file version.env "$@"
```

`config/.env` continues to be loaded by the service's `env_file:` key — that is container environment
and is unaffected by `--env-file`, which only feeds compose-file interpolation.

**`run-proxy-local.sh`** — source `version.env` and warn if the binary on `$PATH` doesn't match.
Note: the currently installed binary is `1.2.0-alpha.2`, so this path needs a reinstall:

```bash
curl -sL https://agentgateway.dev/install | bash -s -- --version v1.5.0
```

(Verified: an official install script exists; there is no brew formula and no npm package.)

## B. Fix what the upgrade breaks

1. **`config/agentgateway_config.yaml:1`** — the `$schema=../../schema/local.json` pointer has never
   resolved. Replace with the hosted schema (this is what upstream examples and the binary itself emit):
   ```yaml
   # yaml-language-server: $schema=https://agentgateway.dev/schema/config
   ```
2. **Fix the petstore OpenAPI target.** Add `config/openapi/petstore.json` to the repo and change the
   `docker-compose.yaml` mount to `./config/openapi/petstore.json:/app/openapi.json`. (`schema: {url: …}`
   is also supported if you'd rather not vendor the file, but a checked-in file keeps the demo offline-safe.)
3. **JWT `iss`/`aud`.** Decode a token from `get-keycloak-token.sh` and confirm it carries `iss` and an
   `aud` containing `account`. Keycloak usually emits `aud: ["realm-management","account"]`, which matches
   — but confirm rather than assume, because every `jwtAuth` block in the config sets `audiences: [account]`.
   Do the same for the Auth0 (`/secure/mcp`) and Entra (`/entra/mcp`) `mcpAuthentication` blocks; those
   set `audiences:` to ngrok/`api://` values that DCR-issued tokens may not carry.
4. **Retune `config/ratelimit-config.yaml`** for the new cache-inclusive token counts on the
   `anthropic` and `bedrock` descriptors, or set `AGENTGATEWAY_LEGACY_LLM_USAGE_TOKEN_SEMANTICS=true`
   in `config/.env` as a temporary bridge. Prefer retuning — the flag is going away.
5. **Leave `config.tracing` / `config.logging.fields` as-is.** They still work on 1.5 but are now
   deprecated in favor of `frontendPolicies.tracing` / `frontendPolicies.accessLog`. Mixing the two is
   a hard startup error. If you want to migrate, do it in one shot with `agentgateway migrate -f <file>`
   and commit the result — don't hand-edit half of it.

## C. Showcase the 1.5 features

Additive changes to `config/agentgateway_config.yaml` unless noted.

1. **Admin UI on :15000.** Add `ADMIN_ADDR=0.0.0.0:15000` to `config/.env` and `config/example.env`.
   The existing `15000:15000` publish then actually works. Optionally go further and attach the UI to
   the port-3000 gateway with a root `ui:` section guarded by the Keycloak OIDC you already run — see
   `~/rust/agentgateway/examples/traffic-unified-gateway/config.yaml`.

2. **API-key budgets + model access.** Needs `config.database` (SQLite) plus a named volume in compose
   so the budget survives restarts. New route, e.g. `/keyed/openai`:
   ```yaml
   config:
     database:
       url: /data/agentgateway.db
   ```
   ```yaml
   policies:
     apiKey:
       mode: strict
       location:
         header: {name: authorization, prefix: 'Bearer '}
       keys:
       - key: agw_sk_demo
         metadata: {name: Demo key, owner: platform}
         allowedModels: ["gpt-4o", "gpt-4o-mini"]
         budgets:
         - name: daily-usd
           limit: {unit: USD, amount: 0.50}     # unit is USD | Tokens
           window: {rolling: 24h}               # epoch-aligned, not first-request-aligned
           onBudgetExceeded: Block              # Block | Audit
   ```
   Note `unit: USD` (not `dollars`) and `onBudgetExceeded: Block` (capitalized) — verified against
   `BudgetLimitUnit` / `BudgetExceededAction` in `schema/config.json`. A USD budget only charges when
   the model can be priced, so this depends on C3.

3. **Real cost, from the model catalog.** New `config/model-catalog.json` (format per
   `~/rust/agentgateway/crates/agentgateway/src/llm/catalog/testdata/model_catalog.golden.json` — top-level
   `providers.<name>.models.<id>.rates` with `input`/`output`/`cacheRead`/`cacheWrite` per 1M tokens,
   plus optional `tiers[].contextOver`), referenced as:
   ```yaml
   config:
     modelCatalog:
     - file: /app/model-catalog.json
   ```
   Then add `cost_usd: 'llm.cost.total'` to `config.metrics.fields.add` and `config.logging.fields.add`,
   and rewrite `config/grafana/provisioning/dashboards/cost_analysis_dashboard.json` to use the native
   `agentgateway_gen_ai_client_cost_usd_total` counter instead of its current hardcoded
   price-times-`agentgateway_gen_ai_client_token_usage_sum` PromQL. `agentgateway_cost_catalog_lookups_total`
   (labeled by resolution status) is the diagnostic for catalog misses.

4. **Native Gemini API** on the existing `/gemini` route. Because of fact #5, this must be explicit:
   ```yaml
   ai:
     routes:
       "/v1/chat/completions": completions
       ":generateContent": generateContent
       ":streamGenerateContent": generateContent
       ":countTokens": geminiCountTokens
       "*": passthrough
   ```
   Suffixes are matched with `ends_with`, longest first, `*` last. The model comes from the
   `models/{model}:…` path segment, so no per-model config is needed. Demo beat: point a raw Gemini SDK
   client at agentgateway.

5. **Anthropic Messages → OpenAI Responses.** New route (e.g. `/compat/anthropic`) with an OpenAI
   backend and `ai.routes: {"/v1/messages": messages, "*": passthrough}`. Demo beat: point the Anthropic
   SDK (or Claude Code) at an OpenAI-backed endpoint.

6. **Guardrails over tool calls + streaming.** Upgrade the existing `regex` masks — `scope` is new in 1.5
   and only `regex`/`bedrockGuardrails` accept a non-default scope:
   ```yaml
   ai:
     promptGuard:
       streaming: Enabled
       request:
       - regex:
           action: mask
           rules: [{builtin: ssn}, {builtin: creditCard}, {builtin: email}]
         scope: [systemPrompt, messages, toolInput, toolOutput]
   ```
   Caveat from the schema: `toolInput` masking can rewrite opaque JSON tool args into invalid JSON —
   worth demoing on `messages`/`toolOutput` and mentioning the tradeoff rather than pretending it's free.

7. *(optional, cheap)* **OpenAI inline moderation** as a provider field on the `/openai` backend
   (`provider.openAI.moderation.policy.input.mode: block`) — distinct from the `openAIModeration`
   prompt guard the demo already uses, and a good "gateway config beats client config" talking point.

## D. README

Update `README.md` for: the new version/pinning story (`version.env`, `./run-compose.sh`, the
`curl … | bash -s -- --version v1.5.0` install line), the Admin UI section, and new sections for
budgets/model access, native Gemini, Anthropic→Responses, and tool-call guardrails. Refresh the
"Running agentgateway" block (lines ~37–101) and add the version to the intro.

---

## Files touched

| File | Change |
|---|---|
| `version.env` | **new** — `AGW_VERSION` / `AGW_IMAGE_REPO` |
| `run-compose.sh` | **new** — `docker compose --env-file version.env "$@"` |
| `docker-compose.yaml` | image ref, petstore mount fix, sqlite volume, `ADMIN_ADDR` |
| `config/agentgateway_config.yaml` | schema pointer, `config.database`, `config.modelCatalog`, apiKey/budget route, Gemini + Responses `ai.routes`, guardrail `scope` |
| `config/model-catalog.json` | **new** |
| `config/openapi/petstore.json` | **new** |
| `config/.env`, `config/example.env` | `ADMIN_ADDR`, optional legacy-token flag |
| `config/ratelimit-config.yaml` | retune token descriptors |
| `config/grafana/.../cost_analysis_dashboard.json` | use `agentgateway_gen_ai_client_cost_usd_total` |
| `run-proxy-local.sh` | source `version.env`, version check |
| `README.md` | walkthrough updates |

Also worth fixing while in there: `run-proxy-dev.sh:3` points at `~/scripted-demos/agentgateway/config/…`,
a stale path from a previous repo location.

## Verification

1. **Static validation first** (new in 1.5, no containers needed):
   ```bash
   docker run --rm -v "$PWD/config:/app/config" --env-file config/.env \
     cr.agentgateway.dev/agentgateway:v1.5.0 -f /app/config/agentgateway_config.yaml --validate-only
   ```
2. `./run-compose.sh up -d && ./run-compose.sh logs -f agentgateway` — clean startup, no deprecation errors.
3. Smoke the existing routes with the curls already in `README.md`: `/gemini`, `/openai`, `/anthropic`,
   `/bedrock`, plus `/mcp` and `/public/mcp` via
   `npx @modelcontextprotocol/inspector --cli http://localhost:3000/mcp --transport http --method tools/list`
   — the `openapi` petstore tools should now appear (they don't today).
4. **JWT**: `./get-keycloak-token.sh`, decode the payload, confirm `iss` and `aud`, then exercise
   `/openai` (jwt.sub rule), `/policy/openai` (supply-chain role) and `/mcp` (mcpAuthorization rules).
5. **Budgets**: call `/keyed/openai` with `Authorization: Bearer agw_sk_demo` in a loop until the USD
   budget trips; confirm a block, then confirm a request for a model outside `allowedModels` is refused.
   Check `agentgateway_cost_catalog_lookups_total` on `:15020/metrics` for catalog misses.
6. **Cost**: `curl localhost:15020/metrics | grep cost_usd` is non-zero, and the Grafana cost dashboard
   (localhost:3001) renders from the native counter.
7. **Native Gemini**: `POST /gemini/v1beta/models/gemini-2.5-flash-lite:generateContent` returns a Gemini-shaped
   response; **Responses**: `POST /compat/anthropic/v1/messages` against the OpenAI backend returns an
   Anthropic-shaped response.
8. **Rate limits**: hammer `/anthropic` and confirm the 429 threshold is where the demo script expects it
   after the retune.
9. **Admin UI**: `http://localhost:15000` loads.
