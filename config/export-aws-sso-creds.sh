#!/usr/bin/env bash
# Export current AWS SSO (or profile) credentials to a file that can be sourced
# before starting agentgateway. Agentgateway uses the default credential chain,
# which reads AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN from
# the environment when using implicit AWS backend auth.
#
# Usage:
#   ./export-aws-sso-creds.sh [--profile PROFILE] [OUTPUT_FILE]
#
# Then start agentgateway with credentials in the environment:
#   source ./aws-creds.env   # or whatever OUTPUT_FILE you used
#   agentgateway --config config.yaml
#
# Credentials are short-lived (e.g. 8–12 hours); re-run this script and
# restart agentgateway when they expire.

set -e

PROFILE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "$PROFILE" ]]; then
  CREDENTIALS=$(aws configure export-credentials --profile "$PROFILE" --format env)
else
  CREDENTIALS=$(aws configure export-credentials --format env)
fi

# Optionally append default region from profile so agentgateway can resolve region
if [[ -n "$PROFILE" ]]; then
  REGION=$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)
else
  REGION=$(aws configure get region 2>/dev/null || true)
fi
# Parse credentials and region
AWS_ACCESS_KEY_ID=$(echo "$CREDENTIALS" | grep AWS_ACCESS_KEY_ID | cut -d '=' -f 2 | tr -d '"')
AWS_SECRET_ACCESS_KEY=$(echo "$CREDENTIALS" | grep AWS_SECRET_ACCESS_KEY | cut -d '=' -f 2 | tr -d '"')
AWS_SESSION_TOKEN=$(echo "$CREDENTIALS" | grep AWS_SESSION_TOKEN | cut -d '=' -f 2 | tr -d '"')

# Function to update .env files
update_env_file() {
  local ENV_FILE="$1"
  local TEMP_FILE=$(mktemp)

  # Create file if it doesn't exist
  touch "$ENV_FILE"

  # Use awk to replace or add AWS credential lines
  awk -v AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
      -v AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
      -v AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
      -v AWS_DEFAULT_REGION="$REGION" \
      -v AWS_REGION="$REGION" \
      '{
        if ($0 ~ /^AWS_ACCESS_KEY_ID=/) { print "AWS_ACCESS_KEY_ID=\"" AWS_ACCESS_KEY_ID "\"" ; found_access_key=1 }
        else if ($0 ~ /^AWS_SECRET_ACCESS_KEY=/) { print "AWS_SECRET_ACCESS_KEY=\"" AWS_SECRET_ACCESS_KEY "\"" ; found_secret_key=1 }
        else if ($0 ~ /^AWS_SESSION_TOKEN=/) { print "AWS_SESSION_TOKEN=\"" AWS_SESSION_TOKEN "\"" ; found_session_token=1 }
        else if ($0 ~ /^AWS_DEFAULT_REGION=/) { print "AWS_DEFAULT_REGION=\"" AWS_DEFAULT_REGION "\"" ; found_default_region=1 }
        else if ($0 ~ /^AWS_REGION=/) { print "AWS_REGION=\"" AWS_REGION "\"" ; found_region=1 }
        else { print }
      } END {
        if (!found_access_key) print "AWS_ACCESS_KEY_ID=\"" AWS_ACCESS_KEY_ID "\""
        if (!found_secret_key) print "AWS_SECRET_ACCESS_KEY=\"" AWS_SECRET_ACCESS_KEY "\""
        if (!found_session_token) print "AWS_SESSION_TOKEN=\"" AWS_SESSION_TOKEN "\""
        if (!found_default_region && AWS_DEFAULT_REGION != "") print "AWS_DEFAULT_REGION=\"" AWS_DEFAULT_REGION "\""
        if (!found_region && AWS_REGION != "") print "AWS_REGION=\"" AWS_REGION "\""
      }' "$ENV_FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$ENV_FILE"
  echo "Updated credentials in $ENV_FILE"
}

update_env_file ".env"
update_env_file ".env.local"


