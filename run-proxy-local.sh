#!/usr/bin/env bash
# Run agentgateway from a locally installed binary (no containers).
# Install/upgrade the binary with:
#   curl -sL https://agentgateway.dev/install | bash -s -- --version "$AGW_VERSION"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ./version.env

# `agentgateway --version` emits JSON; release builds report the tag in .version,
# builds from source report a bare git sha instead.
installed=$(agentgateway --version 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)
if [[ "$installed" != "$AGW_VERSION" ]]; then
  echo "WARNING: agentgateway on PATH reports '${installed:-unknown}', version.env pins ${AGW_VERSION}." >&2
  echo "         curl -sL https://agentgateway.dev/install | bash -s -- --version ${AGW_VERSION}" >&2
  echo >&2
fi

set -a
source ./config/.env.local
set +a

exec agentgateway -f config/agentgateway_config.yaml
