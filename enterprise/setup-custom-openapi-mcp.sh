#!/usr/bin/env bash
# Sets up the custom-openapi-mcp demo.
#
# Deploys Swagger Petstore3 in-cluster and configures an EnterpriseAgentgatewayBackend
# with one `custom` MCP target per Petstore operation (get-pet-by-id,
# find-pets-by-status, add-pet, update-pet, get-inventory, delete-pet).
# Each tool translates directly to an HTTP call against the in-cluster petstore.
#
# Prerequisite: ./setup-gateway.sh must already be run.
#
# MCP endpoint: http://localhost:3000/custom-openapi-mcp/mcp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
set -a
source .env
set +a

kubectl apply -f ./resources/openapi-mcp/petstore-deployment.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-custom-backend.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-custom-httproute.yaml

echo ""
echo "Waiting for petstore to be ready..."
kubectl wait deployment/petstore -n agentgateway-system --for=condition=Available --timeout=60s

echo ""
echo "MCP endpoint: http://localhost:3000/custom-openapi-mcp/mcp"
echo "Port-forward if needed: kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080"
echo ""
echo "Quick test (tools/list):"
echo "  curl -s -X POST http://localhost:3000/custom-openapi-mcp/mcp \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Accept: application/json, text/event-stream' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
