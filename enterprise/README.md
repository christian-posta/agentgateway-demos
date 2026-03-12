# Solo.io Enterprise Agentgateway

You must have a running cluster.

You also need an enterprise license key.

```bash
# Install gateway
./setup-gateway.sh

# Install observability
./setup-observability.sh
```

From here, you need to portforward agentgateway

```bash
kubectl port-forward deployments/agentgateway -n agentgateway-system 3000:8080
```

If you need the backend config:

```bash
kubectl port-forward deployments/agentgateway -n agentgateway-system 15000

curl http://localhost:15000/config_dump
```

For metrics, tracing, dashboards:

```bash
kubectl port-forward -n monitoring svc/grafana-prometheus 3002:3000       
```


## Set up Elicitations

Elicitations can be demo'd by setting up the following:

```bash
./setup-elicitation.sh
```
This sets up the routes, secrets, and mcp configs. The MCP Auth is tied to the public keycloak we also use for the UI. 

To demo this, you will want to use the `kagent-ui` client id since that Keycloak doesn't support DCR.


Perform necessary port forwards to access the UI and backend
```bash
kubectl port-forward service/solo-enterprise-ui -n kagent  4000:80 
kubectl port-forward deployments/agentgateway-enterprise -n agentgateway-system 3000:8080 
```

If you want to manually call a route, you can use this helper to get a token:

```bash
export TOKEN=$(curl -k -X POST "https://demo-keycloak-907026730415.us-east4.run.app/realms/kagent-dev/protocol/openid-connect/token" \
-d "client_id=kagent-ui" \
-d "username=admin" \
-d 'password=$KEYCLOAK_USER_PASSWORD' \
-d "grant_type=password" | jq -r .access_token)
```


Best way to demo this is with MCP inspector or VS Code. Use the `kagent-ui` client id. 

Go to the `https://ceposta-agw.ngrok.io/github-copilot/mcp` or the databricks: `https://ceposta-agw.ngrok.io/github-copilot/mcp`

It will prompt you to login through Keyclaok (representing SSO). 

Once successfully auth'd youd still get an error message telling you to go to the Agentgateway UI. 


There you should see elicitations to complete. 


### Testing Databricks

If you want to manually test databricks for example:

Can test with this:

```bash
export TOKEN=$(curl -k -X POST "https://demo-keycloak-907026730415.us-east4.run.app/realms/kagent-dev/protocol/openid-connect/token" \
-d "client_id=kagent-ui" \
-d "username=admin" \
-d 'password=$KEYCLOAK_USER_PASSWORD' \
-d "grant_type=password" | jq -r .access_token)

curl -X POST localhost:3000/databricks/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'
```

### Testing GitHub CoPilot

```bash
export TOKEN=$(curl -k -X POST "https://demo-keycloak-907026730415.us-east4.run.app/realms/kagent-dev/protocol/openid-connect/token" \
-d "client_id=kagent-ui" \
-d "username=admin" \
-d 'password=$KEYCLOAK_USER_PASSWORD' \
-d "grant_type=password" | jq -r .access_token)

curl -X POST localhost:3000/github-copilot/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'
```

Or with mcp-inspector:

```bash
npx @modelcontextprotocol/inspector@0.18.0 --header "Authorization: Bearer $TOKEN" --cli http://localhost:3000/github-copilot/mcp --transport http --method tools/list
```