set -a
source ./config/.env.local
set +a

agentgateway -f config/agentgateway_config.yaml
