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
This sets up the routes, secrets, and mcp configs. The MCP Auth is tied to Auth0 (`ceposta-solo.auth0.com`).

To demo this, you can use the hardcoded client ID for mcp-inspector: `0x1gCuvq2XeMG8yUmnCna4JJiPpv82ID`


Perform necessary port forwards to access the UI and backend
```bash
kubectl port-forward service/solo-enterprise-ui -n kagent  4000:80 
kubectl port-forward deployments/agentgateway-enterprise -n agentgateway-system 3000:8080 
```

If you want to manually call a route, use `get-auth0-token.sh` to obtain a token:

```bash
./get-auth0-token.sh
```

Set `SCOPE` and ensure the script's `AUDIENCE` matches the elicitation route (e.g. `https://ceposta-agw.ngrok.io/mcp`).


Best way to demo this is with MCP Inspector or VS Code. Use client ID `0x1gCuvq2XeMG8yUmnCna4JJiPpv82ID` for mcp-inspector.

Go to `https://ceposta-agw.ngrok.io/github-copilot/mcp` or `https://ceposta-agw.ngrok.io/databricks/mcp`

It will prompt you to login through Auth0 (representing SSO). 

Once successfully auth'd you'll still get an error message telling you to go to the Agentgateway UI. 


There you should see elicitations to complete. 


### Testing Databricks

If you want to manually test databricks for example:

Can test with this (get a token first via `./get-auth0-token.sh` with `AUDIENCE=https://ceposta-agw.ngrok.io/mcp`):

```bash
export TOKEN=$(./get-auth0-token.sh)

curl -X POST localhost:3000/databricks/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'
```

### Testing GitHub CoPilot

```bash
export TOKEN=$(./get-auth0-token.sh)

curl -X POST localhost:3000/github-copilot/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}'
```

Or with MCP Inspector (use client ID `0x1gCuvq2XeMG8yUmnCna4JJiPpv82ID` when prompted):

```bash
npx @modelcontextprotocol/inspector@0.18.0 --header "Authorization: Bearer $TOKEN" --cli http://localhost:3000/github-copilot/mcp --transport http --method tools/list
```