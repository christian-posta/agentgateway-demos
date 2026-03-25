set -a
source .env
set +a


kubectl apply -f ./resources/mcp/public.yaml
kubectl apply -f ./resources/mcp/jwt-secure.yaml
kubectl apply -f ./resources/mcp/public-oauth.yaml
kubectl apply -f ./resources/mcp/mcp-oidc.yaml

envsubst < ./resources/mcp/public-oauth-entra.yaml | kubectl apply -f -