#!/usr/bin/env bash
# Sets up all OpenAPI → MCP petstore demos under resources/openapi-mcp/.
#
# Deploys Swagger Petstore3 in-cluster and:
#   - custom-openapi-mcp — custom tool per OpenAPI operation (petstore-custom-*)
#   - code-openapi-mcp — single run_code tool (QuickJS) (petstore-code-*)
#   - secure-openapi-mcp — same custom backend + JWT/MCP OAuth policy (petstore-secure-*)
#
# Prerequisite: ./setup-gateway.sh must already be run.
#
# MCP endpoints (with gateway on localhost:3000):
#   http://localhost:3000/custom-openapi-mcp/mcp
#   http://localhost:3000/code-openapi-mcp/mcp
#   http://localhost:3000/secure-openapi-mcp/mcp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
set -a
source .env
set +a

kubectl apply -f ./resources/openapi-mcp/petstore-deployment.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-custom-backend.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-code-backend.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-custom-httproute.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-code-httproute.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-secure-httproute.yaml

echo ""
echo "Waiting for petstore to be ready..."
kubectl wait deployment/petstore -n agentgateway-system --for=condition=Available --timeout=60s

echo ""
echo "Port-forward if needed: kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080"
echo ""
echo "custom-openapi-mcp:  http://localhost:3000/custom-openapi-mcp/mcp"
echo "code-openapi-mcp:    http://localhost:3000/code-openapi-mcp/mcp"
echo "secure-openapi-mcp:  http://localhost:3000/secure-openapi-mcp/mcp"
echo "  OAuth discovery:"
echo "    http://localhost:3000/.well-known/oauth-protected-resource/secure-openapi-mcp/mcp"
echo "    http://localhost:3000/.well-known/oauth-authorization-server/secure-openapi-mcp/mcp"
echo ""
echo "Quick test (initialize on custom route):"
echo "  curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Accept: application/json, text/event-stream' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
echo ""
echo "Code mode (tools/list — expect one tool: run_code):"
echo "  curl -s -X POST http://localhost:3000/code-openapi-mcp/mcp \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Accept: application/json, text/event-stream' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
echo ""
echo "Secure route (unauthenticated initialize should return 401):"
echo "  curl -i -X POST http://localhost:3000/secure-openapi-mcp/mcp \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Accept: application/json, text/event-stream' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
echo ""
echo "OAuth discovery (no auth):"
echo "  curl -s http://localhost:3000/.well-known/oauth-protected-resource/secure-openapi-mcp/mcp"
