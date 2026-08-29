#!/usr/bin/env bash
# Wrapper around docker compose that feeds version.env into compose-file interpolation.
#
# version.env is the single source of truth for the agentgateway image ref, so
# `docker compose` must not be invoked directly -- ${AGW_IMAGE_REPO}:${AGW_VERSION}
# would resolve to ":" and the pull would fail.
#
# This is separate from config/.env, which the service's env_file: key loads as
# *container* environment. --env-file only feeds interpolation of the compose file.
#
#   ./run-compose.sh up -d
#   ./run-compose.sh logs -f agentgateway
#   ./run-compose.sh down
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# -p is mandatory, not cosmetic. Without it compose derives the project name from the
# directory it was launched through, and this tree is reachable by more than one path
# (~/agw-demos -> ...). Launching via a different path yields a DIFFERENT project name,
# so compose builds a whole second stack -- new network, new volume, duplicate port
# publishes -- instead of touching the running one.
exec docker compose -p agentgateway-demos --env-file version.env "$@"
