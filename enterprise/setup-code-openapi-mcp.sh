#!/usr/bin/env bash
# Sets up the code-openapi-mcp demo.
#
# Same Petstore3 backend as the custom-openapi-mcp demo, but with
# toolMode: Code. In Code Mode the gateway exposes a single `run_code` tool
# whose description lists every petstore operation as a JS async function.
# The model sends JavaScript; the gateway runs it in a QuickJS sandbox.
#
# Prerequisite: ./setup-gateway.sh must already be run.
# The petstore deployment is applied idempotently, so this script is
# standalone (does not require setup-custom-openapi-mcp.sh to run first).
#
# MCP endpoint: http://localhost:3000/code-openapi-mcp/mcp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
set -a
source .env
set +a

kubectl apply -f ./resources/openapi-mcp/petstore-deployment.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-code-backend.yaml
kubectl apply -f ./resources/openapi-mcp/petstore-code-httproute.yaml

echo ""
echo "Waiting for petstore to be ready..."
kubectl wait deployment/petstore -n agentgateway-system --for=condition=Available --timeout=60s

echo ""
echo "MCP endpoint: http://localhost:3000/code-openapi-mcp/mcp"
echo "Port-forward if needed: kubectl port-forward -n agentgateway-system svc/agentgateway 3000:8080"
echo ""
echo "Quick test (tools/list — expect exactly one tool: run_code):"
echo "  curl -s -X POST http://localhost:3000/code-openapi-mcp/mcp \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Accept: application/json, text/event-stream' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
