#!/usr/bin/env bash
# Extract Authorization: Bearer tokens from Agentgateway request logs.
#
# Logs include rq.headers.authorization on MCP/HTTP requests (see agentgateway
# logging.fields). Useful for inspecting OBO exchanged tokens in the OBO demo.
#
# Usage:
#   ./get-bearer-from-logs.sh              # latest bearer token (raw JWT)
#   ./get-bearer-from-logs.sh -d           # decode JWT header + payload
#   ./get-bearer-from-logs.sh -f           # follow logs, print tokens as they appear
#   ./get-bearer-from-logs.sh --obo        # only tokens issued by AGW STS (OBO)
#   ./get-bearer-from-logs.sh --export     # print: export TOKEN='...'
#
# Environment overrides:
#   NAMESPACE=agentgateway-system
#   DEPLOYMENT=agentgateway
#   TAIL=200

set -euo pipefail

NAMESPACE="${NAMESPACE:-agentgateway-system}"
DEPLOYMENT="${DEPLOYMENT:-agentgateway}"
TAIL="${TAIL:-200}"

FOLLOW=false
DECODE=false
EXPORT=false
OBO_ONLY=false
UNIQUE=true

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -f|--follow) FOLLOW=true; shift ;;
    -d|--decode) DECODE=true; shift ;;
    -a|--all) UNIQUE=false; shift ;;
    --obo) OBO_ONLY=true; shift ;;
    -e|--export) EXPORT=true; shift ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    --tail) TAIL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

jwt_decode_part() {
  local token="$1" part="$2" num
  if [[ "$part" == "header" ]]; then num=1; else num=2; fi
  local b64 len rem decoded
  b64=$(echo "$token" | cut -d. -f"$num")
  [[ -z "$b64" ]] && return 0
  b64=$(echo "$b64" | sed 's/-/+/g; s/_/\//g')
  len=${#b64}
  rem=$((len % 4))
  [[ "$rem" -eq 2 ]] && b64="${b64}=="
  [[ "$rem" -eq 3 ]] && b64="${b64}="
  decoded=$(echo "$b64" | base64 -d 2>/dev/null) || decoded=$(echo "$b64" | base64 -D 2>/dev/null)
  [[ -z "$decoded" ]] && return 0
  echo "--- JWT $part ---"
  if command -v jq >/dev/null 2>&1; then
    echo "$decoded" | jq '.' 2>/dev/null || echo "$decoded"
  else
    echo "$decoded"
  fi
  echo ""
}

is_obo_token() {
  local token="$1" payload len rem
  payload=$(echo "$token" | cut -d. -f2 | sed 's/-/+/g; s/_/\//g')
  [[ -z "$payload" ]] && return 1
  len=${#payload}
  rem=$((len % 4))
  [[ "$rem" -eq 2 ]] && payload="${payload}=="
  [[ "$rem" -eq 3 ]] && payload="${payload}="
  payload=$(echo "$payload" | base64 -d 2>/dev/null) || payload=$(echo "$payload" | base64 -D 2>/dev/null)
  [[ -z "$payload" ]] && return 1
  echo "$payload" | grep -q 'enterprise-agentgateway' 2>/dev/null
}

emit_token() {
  local token="$1"
  if $OBO_ONLY && ! is_obo_token "$token"; then
    return 0
  fi
  if $DECODE; then
    jwt_decode_part "$token" header
    jwt_decode_part "$token" payload
  fi
  if $EXPORT; then
    printf "export TOKEN='%s'\n" "$token"
  else
    echo "$token"
  fi
}

extract_tokens_from_line() {
  grep -oE '"rq\.headers\.authorization":"Bearer [^"]+"' || true
}

process_line() {
  local line="$1" match token
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    token="${match#\"rq.headers.authorization\":\"Bearer }"
    token="${token%\"}"
    if $UNIQUE; then
      if ((${#seen_tokens[@]})) && printf '%s\n' "${seen_tokens[@]}" | grep -qxF "$token" 2>/dev/null; then
        continue
      fi
      seen_tokens+=("$token")
    fi
    emit_token "$token"
    found=true
    if $UNIQUE && ! $FOLLOW; then
      return 0
    fi
  done < <(extract_tokens_from_line <<< "$line")
}

kubectl_args=(logs -n "$NAMESPACE" "deploy/${DEPLOYMENT}")
if $FOLLOW; then
  kubectl_args+=(--follow)
else
  kubectl_args+=(--tail="$TAIL")
fi

seen_tokens=()
found=false
while IFS= read -r line; do
  process_line "$line"
  if $UNIQUE && $found && ! $FOLLOW; then
    break
  fi
done < <(kubectl "${kubectl_args[@]}" 2>/dev/null) || {
  echo "Error: failed to read logs from deploy/${DEPLOYMENT} in ${NAMESPACE}" >&2
  echo "Hint: kubectl get pods -n ${NAMESPACE}" >&2
  exit 1
}

if ! $found && ! $FOLLOW; then
  echo "No bearer token found in last ${TAIL} log lines (try --tail or trigger a request)" >&2
  exit 1
fi
