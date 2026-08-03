---
name: validate-agw-release
description: Stand up a kind-based validation environment for a new Enterprise Agentgateway release (version read from enterprise/version.env) and drive the manual README.md demo walkthrough. Use when validating an agentgateway release candidate, running a pre-release smoke test, spinning up a versioned kind cluster named agw-<version>, or when the user asks to "validate", "test", or "smoke" a new agentgateway chart/version.
---

# Validate Agentgateway Release

This skill validates a new Enterprise Agentgateway release end-to-end on a dedicated `kind` cluster. It runs four focused setup scripts to bring up the environment and then hands off to the manual `README.md` walkthrough (including OPA/OpenFGA external policy engines).

## Scope

- **In scope:** `enterprise/setup-gateway.sh`, `enterprise/setup-llms.sh`, `enterprise/setup-mcp.sh`, `enterprise/setup-elicitation.sh`
- **Explicitly out of scope:** `enterprise/setup-obo.sh`, `enterprise/setup-msft-obo.sh`, `enterprise/setup-observability.sh` (run manually only if metrics/Grafana are needed for this validation pass)

## Prerequisites

Verify before doing anything destructive:

1. Tools on PATH: `docker`, `kind`, `kubectl`, `helm`, `envsubst` (gettext), `jq`.
2. Docker daemon is running.
3. **Assume `enterprise/.env` is present and correct.** Do not open, read, grep, summarize, or display the contents of `enterprise/.env`. The user maintains it. Variable names are documented in `enterprise/example.env` for human reference only. **Do source it** at the start of the walkthrough (Step 9) to load env vars like `CLIENT_SECRET` into the shell — sourcing is fine, displaying contents is not.
4. No existing kind cluster with the derived name (check `kind get clusters`).

If a tool or cluster check fails, stop and report it. If setup scripts fail with missing-env or auth errors, tell the user to fix `enterprise/.env` on their machine — still do not read that file.

## Cluster naming

Read the chart version from `enterprise/version.env` and sanitize dots to dashes:

```bash
ENTERPRISE_AGW_VERSION=$(grep ENTERPRISE_AGW_VERSION enterprise/version.env | cut -d= -f2)
CLUSTER_NAME="agw-$(echo "$ENTERPRISE_AGW_VERSION" | tr '.' '-')"
echo "Cluster: $CLUSTER_NAME"
```

Example: `ENTERPRISE_AGW_VERSION=v2.3.0-rc.3` -> `CLUSTER_NAME=agw-v2-3-0-rc-3`.

## Workflow checklist

Track progress through these steps. Only ONE step in_progress at a time.

```
- [ ] 1. Pre-flight checks (tools, Docker, cluster name; assume `.env` present — do not read it)
- [ ] 2. Compute CLUSTER_NAME from enterprise/version.env
- [ ] 3. kind create cluster + kubectl context switch
- [ ] 4. enterprise/setup-gateway.sh (verify rollouts + Programmed Gateway)
- [ ] 5. enterprise/setup-llms.sh (verify LLM secrets + HTTPRoutes)
- [ ] 6. enterprise/setup-mcp.sh (verify MCP HTTPRoutes)
- [ ] 7. enterprise/setup-elicitation.sh (verify token-exchange secrets)
- [ ] 8. Port-forward :3000 (gateway) and :4000 (UI); smoke-test Gemini curl
- [ ] 9. Hand off to README.md manual walkthrough (+ OPA/OpenFGA)
- [ ] 10. Stop background port-forwards (leave cluster running)
```

## Step-by-step

### Step 3: Cluster bring-up

```bash
kind create cluster --name "$CLUSTER_NAME"
kubectl config use-context "kind-$CLUSTER_NAME"
kubectl get nodes   # expect Ready
```

### Step 4: `enterprise/setup-gateway.sh`

Must run from `enterprise/` so it can `source .env` and `version.env`. This script:

- Installs Gateway API v1.5.0 standard CRDs
- Installs `enterprise-agentgateway-crds` and `enterprise-agentgateway` at `$ENTERPRISE_AGW_VERSION` into `agentgateway-system`
- Applies `resources/setup/supporting.yaml` (EnterpriseAgentgatewayParameters), `resources/setup/gateway.yaml` (Gateway listener :8080), and `resources/supporting/failover-429.yaml`
- Installs `kagent-mgmt` Helm chart (Solo Enterprise UI) into `kagent` namespace

Run and validate:

```bash
cd enterprise
./setup-gateway.sh

kubectl -n agentgateway-system rollout status deploy/enterprise-agentgateway --timeout=180s
kubectl -n agentgateway-system wait --for=condition=Programmed gateway/agentgateway --timeout=120s
kubectl -n kagent rollout status deploy/solo-enterprise-ui --timeout=180s
```

### Step 5: `enterprise/setup-llms.sh`

Creates `openai-secret`, `anthropic-secret`, `gemini-secret`, `bedrock-secret`, applies base LLM routes (openai/anthropic/gemini/bedrock) and advanced ones (failover, model-armor, bedrock-guardrail, openai-policy, openai-opa-policy, gemini-a2as).

```bash
./setup-llms.sh
kubectl -n agentgateway-system get httproute
kubectl -n agentgateway-system get secrets | grep -E 'openai|anthropic|gemini|bedrock'
```

### Step 6: `enterprise/setup-mcp.sh`

Applies `public.yaml`, `jwt-secure.yaml`, `public-oauth.yaml`, `mcp-oidc.yaml` and renders `public-oauth-entra.yaml` via `envsubst` (needs `ENTRA_TENANT_ID`).

```bash
./setup-mcp.sh
kubectl -n agentgateway-system get httproute | grep mcp
```

### Step 7: `enterprise/setup-elicitation.sh`

Creates `github-token-exchange` and `databricks-token-exchange` secrets and applies `resources/elicitation/databricks-mcp.yaml` and `github-copilot-mcp.yaml`. The script runs `kubectl delete secret ...` first; on a fresh cluster that prints `NotFound` once — expected, non-fatal.

```bash
./setup-elicitation.sh
kubectl -n agentgateway-system get secret github-token-exchange databricks-token-exchange
```

### Step 8: Port-forwards + smoke test

**YOU (Claude) must start the port-forwards using the Bash tool** with `run_in_background: true`. Do not ask the user to open terminals.

```bash
# Start port-forwards in the background and record their PIDs for teardown
kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080 &>/tmp/pf-agw.log &
echo $! > /tmp/pf-agw.pid
kubectl port-forward -n kagent svc/solo-enterprise-ui 4000:80 &>/tmp/pf-ui.log &
echo $! > /tmp/pf-ui.pid
```

Wait ~5 seconds for the port-forwards to establish, then verify `:3000` is accepting connections:

```bash
sleep 5
curl -s --max-time 5 http://localhost:3000/gemini/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemini-2.5-flash-lite","messages":[{"role":"user","content":"ping"}]}' \
  &>/dev/null && echo "Port-forward :3000 OK" || echo "Port-forward :3000 NOT ready"
```

If `:3000` is not ready after 5s, wait another 5s and retry once before failing.

> **Note:** Use `svc/agentgateway` (not `deploy/enterprise-agentgateway`) for data-plane traffic on port 3000. The `enterprise-agentgateway` deployment exposes only ports 9978/9093/9092/7777 (control plane); the Envoy proxy pod (`deploy/agentgateway`) handles port 8080 but only exposes 15020 directly. Port-forwarding to the `agentgateway` **service** is the correct approach.

Smoke test (Gemini has no auth + no rate limit enforced):

```bash
curl -s http://localhost:3000/gemini/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemini-2.5-flash-lite","messages":[{"role":"user","content":"hello"}]}' | jq .
```

A 200 with a populated `choices[0].message.content` means the data plane is healthy.

### Step 9: Automated test suite (Claude drives — do NOT hand off to the user)

**YOU (Claude) must run the test script using the Bash tool.** Do not ask the user to run it. Do not hand off to README.md. Run the script, capture its output, and relay the summary table.

```bash
cd /Users/ceposta/Dropbox/postamac-share/dev/code/agentgateway-demos
enterprise/validate/run-tests.sh
```

The script (`enterprise/validate/run-tests.sh`) covers all 20 automated tests:

| # | What it tests |
|---|---------------|
| 1–3 | Gemini / Anthropic / Bedrock unified API (no auth) → 200 |
| 4–5 | OpenAI SSO gate: no token → 403; Keycloak token → 200 |
| 6 | Anthropic rate limit (500 tok/min) → 429 on second large request |
| 7 | Failover: gpt-5 → failover-429 → should retry secondary gpt-4o |
| 8–11 | Guardrails: CC masking, OpenAI moderation, Model Armor webhook, Bedrock webhook |
| 12–13 | CEL policy: mcp-user (supply-chain role) → 200; other-user → 403 |
| 14–15 | OPA ext_authz: gpt-4o denied; gpt-3.5-turbo + header allowed |
| 16–18 | A2AS: Turn 1, Turn 2 multi-turn, prompt injection refused |
| 19–20 | MCP /public/mcp tools listed; /mcp role-gated (mcp-user > other-user) |
| 21–23 | MCP Search mode (/search/mcp): 2 meta-tools only; get_tool; invoke_tool real backend |
| S1–S3 | SKIP: Auth0 DCR, OpenFGA, Observability (require browser/manual setup) |

The script auto-starts dependencies (OPA via `docker run -d`, guardrail Flask servers)
if they are not already running. It prints a coloured PASS/FAIL/SKIP table and exits
non-zero if any test fails.

**Important notes the script already handles:**
- OPA health returns `{}` not `{"status":"ok"}` — the script checks correctly
- MCP responses are SSE format with multi-line JSON; `enterprise/validate/parse-mcp-sse.py` handles this
- Each Bash invocation re-sources `enterprise/.env` for Keycloak tokens
- Bedrock FAIL notes "expired creds" when auth error detected

After the script finishes, report the full summary table output to the user verbatim.
Then note any FAILs with your assessment (bug, config issue, or expired credentials).

**Callouts for reference when interpreting results:**

- **Two different IdPs — do not conflate them.**
  - **Auth0 (`ceposta-solo.auth0.com`):** Used for the **Solo Enterprise / management UI** path (`setup-gateway.sh` installs `kagent-mgmt` with OIDC issuer `https://ceposta-solo.auth0.com/`, and the controller Helm values point token-exchange JWKS validators at Auth0). Confirm login flows for the UI on port 4000 against this integration.
  - **Keycloak (local):** Applied gateway routes under `enterprise/resources/` typically validate JWTs with issuer `http://localhost:8080/realms/mcp-realm` and JWKS via the `keycloak-jwks` backend (see e.g. `enterprise/resources/llm/openai.yaml`). **Assume Keycloak is running on the host at port 8080** for README-style curls. Use `./get-keycloak-token.sh` from the repo root for bearer tokens to `/openai`, `/policy/openai`, `/opa/openai`, `/fga/openai`, `/a2as/gemini`, and JWT-secured `/mcp` (`jwt-secure.yaml`). On kind, pods reach Keycloak through `host.docker.internal:8080` per those YAMLs — Keycloak must be listening on the host.
    - **Keycloak CLIENT_SECRET:** stored in `enterprise/.env` as `CLIENT_SECRET`. Sourcing `enterprise/.env` (as shown above) makes it available. The script defaults to `changeme` if not set, which will fail.
    - **Routes that need Keycloak JWT:** `/openai`, `/anthropic` (with auth), `/policy/openai`, `/opa/openai` (optional but enables JWT-in-metadata), `/fga/openai` (needs `mcp-user` sub for OpenFGA lookup), `/a2as/gemini`, `/mcp` (jwt-secure role-gated tools).
  - **Auth0 again (data-plane MCP OAuth / elicitation):** Some MCP and elicitation YAML use Auth0 as the JWT/OAuth provider (e.g. `public-oauth.yaml`, `mcp-oidc.yaml`, elicitation routes). Use `./get-auth0-token.sh` from the **repo root** (not `enterprise/`) — it uses the Auth0 Device Code flow and prints a browser URL to authorize. Run it, visit the URL, approve, then capture the token from its output.
    ```bash
    ./get-auth0-token.sh > /tmp/auth0-flow.txt 2>&1 &
    # Visit the printed URL, approve, then:
    AUTH0_TOKEN=$(awk '/--- Raw token ---/{found=1; next} found{print; exit}' /tmp/auth0-flow.txt | tr -d '[:space:]')
    ```
    - **Routes that need Auth0 JWT:** `/secure/mcp` (public-oauth), `/oidc/mcp` (mcp-oidc), `/databricks/mcp`, `/github-copilot/mcp` (elicitation). Set `AUDIENCE=https://ceposta-agw.ngrok.io/mcp` for elicitation routes.
    - **Auth0 tokens are rejected** by Keycloak-protected routes (issuer mismatch) and by the Entra route (returns 401 — correct behavior to verify).
- OPA: start the external ext_authz server before hitting `/opa/openai`:
  ```bash
  cd policy/opa-policy-engine && ./run-opa.sh   # :8181 HTTP, :9191 gRPC
  ```
  Validate: `gpt-4o` without `x-opa-passthrough-enabled: true` is denied; `gpt-3.5-turbo` with that header is allowed.
- OpenFGA: follow `policy/openfga/README.md` — `./setup-openfga.sh`, `python test-relationships.py`, copy generated `.env` to the `extauth-policy-engine` checkout, then run `./policy-engine`. Validate `/fga/openai` denies `gpt-3.5-turbo` and allows `gpt-4o`.
  - **`/fga/openai` is NOT applied by `setup-llms.sh`** — apply it manually: `kubectl apply -f enterprise/resources/llm/openai-openfga-policy.yaml`
  - **Port conflict:** OPA (`run-opa.sh`) and OpenFGA (`docker compose`) both bind host port 8181. Run them sequentially — stop OPA (`docker stop opa-policy-engine`) before starting OpenFGA, or vice versa. The `policy-engine` (extauth for FGA) runs on port 7070; if another service (e.g. `aauth-service` from `extauth-aauth-resource`) is already on 7070, stop it first.
  - **Python for `test-relationships.py`:** Use `PYTHONPATH=$VENV_PYPATH python3.11 test-relationships.py` (see venv-selection note above). The venvs have `openfga-sdk>=0.9.7` which includes `OpenFgaClient`. The system `pip3` only has 0.1.x which lacks `OpenFgaClient` — do not use system python for this.
  - **OpenFGA UI:** use `https://play.fga.dev/sandbox/?fga_api_host=127.0.0.1:8181&fga_api_scheme=http`. The built-in `localhost:3101/playground` link is broken by design here — it iframes the same hosted sandbox but renders the API host as the in-container `127.0.0.1:8080`, which on the host is Keycloak, not OpenFGA (published on 8181).
  - **In-memory datastore:** `docker-compose.yaml` uses `OPENFGA_DATASTORE_ENGINE: memory`. Every `setup-openfga.sh` run mints a **new** store/model ID, and any container restart wipes all tuples. Never restart the container mid-validation — re-copy the regenerated `.env` to `extauth-policy-engine` and restart `policy-engine` whenever the store is recreated.
- Observability: this skill intentionally does NOT run `setup-observability.sh`. If the metrics/Grafana sections of `README.md` must be validated this pass, run it manually and redo the Grafana section.

### Step 10: Teardown

**Do NOT delete the cluster automatically.** After the test suite finishes, stop only the background port-forwards that were started in Step 8, then report the summary to the user and stop. Leave the cluster running — the user will tear it down manually when ready.

```bash
# Stop port-forwards started in Step 8
kill "$(cat /tmp/pf-agw.pid 2>/dev/null)" 2>/dev/null || true
kill "$(cat /tmp/pf-ui.pid  2>/dev/null)" 2>/dev/null || true
rm -f /tmp/pf-agw.pid /tmp/pf-ui.pid /tmp/pf-agw.log /tmp/pf-ui.log
```

When the user is ready to fully tear down, they can run manually:

```bash
kind delete cluster --name "$CLUSTER_NAME"
# Optional cleanup if started:
#   pkill -f run-opa.sh
#   docker compose -f policy/openfga/docker-compose.yaml down
```

## Pass criteria

- All four setup scripts completed without errors (the one-time `NotFound` from `setup-elicitation.sh` on a fresh cluster is acceptable).
- `kubectl -n agentgateway-system get httproute,gateway,pods` shows everything Ready/Accepted.
- Gemini/Anthropic/Bedrock smoke curls return 200 with expected model names.
- OpenAI (`/openai`) returns 403 without a bearer token; 200 with a valid **Keycloak** token (`./get-keycloak-token.sh`), assuming Keycloak on `:8080`.
- Rate-limit, guardrail, and policy (OPA/FGA) demos produce the documented 403/429/block behavior.
- mcp-inspector can list tools on `/public/mcp` (no auth) and `/mcp` (with **Keycloak** JWT per `jwt-secure.yaml`).

## Key file references

- `enterprise/version.env` — chart version **and chart registry** (`ENTERPRISE_AGW_CHART_REPO`). GA tags (e.g. `v2026.5.2`) live in the public repo `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts` (the default). Dev nightlies (e.g. `v2026.5.0-beta.4-nightly-2026-05-11`) live only in `oci://us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev/charts` — override the var for those. A `not found` on `helm upgrade` almost always means the tag is in the *other* registry, not an auth failure.
- `enterprise/.env` — assumed present; **never read or audit**
- `enterprise/example.env` — variable names for humans (optional reference)
- `enterprise/setup-gateway.sh` — gateway + control plane + UI
- `enterprise/setup-llms.sh` — LLM secrets + routes
- `enterprise/setup-mcp.sh` — MCP routes (needs `ENTRA_TENANT_ID`)
- `enterprise/setup-elicitation.sh` — elicitation routes + token-exchange secrets
- `enterprise/README.md` — enterprise-specific walkthrough
- `README.md` — main demo walkthrough
- `policy/opa-policy-engine/README.md` — OPA setup
- `policy/openfga/README.md` — OpenFGA setup

## Notes / gotchas

- All `enterprise/setup-*.sh` scripts assume `pwd` is `enterprise/`. Always `cd enterprise` first.
- **Venv selection — ARM vs Intel Mac:** The repo has two venvs. Detect which to use at the start of any Python-dependent step:
  ```bash
  REPO=/path/to/agentgateway-demos
  # .venv = ARM Mac (laptop), .venv-desktop = Intel Mac (desktop)
  if [ -d "$REPO/.venv-desktop" ]; then
    VENV_PYPATH="$REPO/.venv-desktop/lib/python3.11/site-packages"
  else
    VENV_PYPATH="$REPO/.venv/lib/python3.11/site-packages"
  fi
  PY311=$(which python3.11)  # /usr/local/bin on Intel, /opt/homebrew/bin on ARM
  # The venv has no python/python3 binary — always invoke via external python3.11 + PYTHONPATH
  ```
  Use `PYTHONPATH=$VENV_PYPATH python3.11 <script>` for all Python invocations (guardrail servers, OpenFGA test-relationships.py, etc.).

- **Guardrail webhook servers** must be started manually before testing `/guardrail/bedrock` and `/guardrail/gemini`:
  ```bash
  REPO=/path/to/agentgateway-demos
  VENV_PYPATH=$( [ -d "$REPO/.venv-desktop" ] && echo "$REPO/.venv-desktop/lib/python3.11/site-packages" || echo "$REPO/.venv/lib/python3.11/site-packages" )
  cd $REPO/guardrail
  PYTHONPATH=$VENV_PYPATH python3.11 bedrock_guardrail.py &>/tmp/bedrock-guardrail.log &
  PYTHONPATH=$VENV_PYPATH python3.11 modelarmor_guardrail.py &>/tmp/modelarmor-guardrail.log &
  ```
  Bedrock webhook listens on `:7273`, Model Armor on `:7272` (both pointing to `host.docker.internal` from inside the cluster).
- Bedrock credentials expire (STS session token). If `/bedrock/v1/...` starts 403'ing mid-validation, refresh with:
  ```bash
  cd enterprise
  aws sts assume-role \
    --profile default \
    --role-arn arn:aws:iam::606469916935:role/bedrock-agentgateway-role \
    --role-session-name agentgateway-lab \
    --duration-seconds 3600 \
    --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
    --output text | ./update-bedrock-credentials.sh
  ```
  The script updates `enterprise/.env` and applies the new `bedrock-secret` to the cluster directly — no need to re-run `setup-llms.sh`. **Important:** Run the `aws sts assume-role` command and pipe its output — do not run `./update-bedrock-credentials.sh` standalone (it uses a `[ -t 0 ]` TTY check that fails in non-interactive shells and will read empty stdin).
- The MCP OAuth demos (`/secure/mcp`, Auth0 DCR flow) are separate from Keycloak JWT on `/mcp`. They expect an HTTPS URL matching the configured audience. In Christian's env that's `https://ceposta-agw.ngrok.io/mcp` via `ngrok http 3000 --url=ceposta-agw.ngrok.io`. If ngrok isn't running, skip those sub-sections rather than marking them failed. Note: Auth0 JWT validation on `/secure/mcp` and `/oidc/mcp` works fine over plain HTTP (localhost:3000) — only the 401 OAuth discovery redirect requires HTTPS.
- Do NOT run `setup-obo.sh` or `setup-msft-obo.sh` as part of this validation.
- **Port-forward for data plane:** always use `svc/agentgateway 3000:8080`, not `deploy/enterprise-agentgateway`. The `enterprise-agentgateway` pod only exposes control-plane ports (9978/9093/9092/7777); the Envoy data-plane pod is `deploy/agentgateway` but is only reachable via the service.
- **Keycloak CLIENT_SECRET:** stored in `enterprise/.env` as `CLIENT_SECRET`. Source `enterprise/.env` before any `get-keycloak-token.sh` call (`set -a && source enterprise/.env && set +a`). Shell env does not persist across Bash invocations — re-source at the top of each command block that needs it.
