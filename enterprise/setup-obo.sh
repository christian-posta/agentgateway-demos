set -a
source .env
set +a

kubectl delete secret google-credentials -n agentgateway-system

kubectl create secret generic google-credentials -n agentgateway-system \
  --from-literal=api-key=${GEMINI_API_KEY}


# Install the agent
kubectl apply -f resources/obo/agent-obo.yaml
kubectl apply -f resources/obo/agent-obo-ui.yaml
kubectl apply -f resources/obo/httproute.yaml  