set -a
source .env
set +a

kubectl delete secret github-token-exchange -n agentgateway-system

kubectl create secret generic github-token-exchange -n agentgateway-system  \
--from-literal=client_id=$GITHUB_CLIENT_ID \
--from-literal=client_secret=$GITHUB_CLIENT_SECRET \
--from-literal=app_id=github \
--from-literal=authorize_url=https://github.com/login/oauth/authorize  \
--from-literal=access_token_url=https://github.com/login/oauth/access_token \
--from-literal=scopes=read:user \
--from-literal=redirect_uri=http://localhost:4000/age/elicitations  \
--dry-run=client -o yaml | kubectl apply  -f -



kubectl delete secret databricks-token-exchange -n agentgateway-system

kubectl create secret generic databricks-token-exchange -n agentgateway-system \
--from-literal=client_id=$DATABRICKS_OAUTH_CLIENT_ID \
--from-literal=client_secret=$DATABRICKS_OAUTH_CLIENT_SECRET \
--from-literal=app_id=databricks \
--from-literal=scopes="genie mcp.genie" \
--from-literal=authorize_url=https://dbc-f1002050-7c6a.cloud.databricks.com/oidc/v1/authorize  \
--from-literal=access_token_url=https://dbc-f1002050-7c6a.cloud.databricks.com/oidc/v1/token \
--from-literal=redirect_uri=http://localhost:4000/age/elicitations  \
--dry-run=client -o yaml | kubectl apply  -f -

kubectl apply -f resources/elicitation/databricks-mcp.yaml
kubectl apply -f resources/elicitation/github-copilot-mcp.yaml