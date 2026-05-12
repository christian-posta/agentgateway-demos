#!/usr/bin/env bash
# Sets up the secure-openapi-mcp demo.
#
# Same petstore custom MCP backend as setup-custom-openapi-mcp.sh, but
# fronted by an EnterpriseAgentgatewayPolicy that uses the newer
# `traffic.jwtAuthentication.mcp` field. The gateway will:
#   - Validate Auth0-issued JWTs on /secure-openapi-mcp/mcp (Strict mode).
#   - Serve MCP OAuth discovery at
#     /.well-known/oauth-protected-resource/secure-openapi-mcp/mcp and
#     /.well-known/oauth-authorization-server/secure-openapi-mcp/mcp.
#   - Enforce per-tool authorization rules using Auth0 permissions
#     (jwt.permissions).
#
# Prerequisites:
#   - ./setup-gateway.sh has been run.
#   - An Auth0 tenant with an API whose identifier matches the `audience` in
#     petstore-secure-httproute.yaml. The example uses
#     `ceposta-solo.auth0.com` (same tenant as resources/mcp/public-oauth.yaml);
#     edit the YAML to point at your own tenant if different.
#
# MCP endpoint: http://localhost:3000/secure-openapi-mcp/mcp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
set -a
source .env
set +a

# Idempotent: applies the petstore deployment + the existing custom backend
# so this script also works standalone (without setup-custom-openapi-mcp.sh
# having been run first).
kubectl apply -f ./resources/openapi-mcp/petstore-deployment.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-custom-backend.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-secure-httproute.yaml

echo ""
echo "Waiting for petstore to be ready..."
kubectl wait deployment/petstore -n agentgateway-system --for=condition=Available --timeout=60s

echo ""
echo "Secure MCP endpoint: http://localhost:3000/secure-openapi-mcp/mcp"
echo "OAuth discovery:"
echo "  http://localhost:3000/.well-known/oauth-protected-resource/secure-openapi-mcp/mcp"
echo "  http://localhost:3000/.well-known/oauth-authorization-server/secure-openapi-mcp/mcp"
echo ""
echo "Port-forward if needed: kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080"
echo ""
echo "Unauthenticated request should return 401:"
echo "  curl -i -X POST http://localhost:3000/secure-openapi-mcp/mcp \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Accept: application/json, text/event-stream' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
echo ""
echo "Discovery endpoint should return JSON metadata without auth:"
echo "  curl -s http://localhost:3000/.well-known/oauth-protected-resource/secure-openapi-mcp/mcp"
