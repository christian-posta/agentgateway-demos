


For this example, since we use `bedrock-agentgateway-role` we need to attach this policy (note the wildcard on the end):

```bash
aws iam put-role-policy \
  --role-name bedrock-agentgateway-role \
  --policy-name AllowInvokeSupplyChainAgent \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "bedrock-agentcore:InvokeAgentRuntime",
        "Resource": "arn:aws:bedrock-agentcore:us-west-2:606469916935:runtime/a2a_supply_chain_agent-CV8obwHtr5*"
      }
    ]
  }'
```

Or if done as inline policy on the UI:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "bedrock-agentcore:InvokeAgentRuntime",
      "Resource": "arn:aws:bedrock-agentcore:us-west-2:606469916935:runtime/a2a_supply_chain_agent-CV8obwHtr5*"
    }
  ]
}
```


Since the agent is an a2a agent, it needs to be called like this:


```bash
curl -X POST \
  "http://localhost:3000/agents/supply-chain-agent" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $(uuidgen)" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"kind": "text", "text": "Hello!"}],
        "messageId": "00000000-0000-0000-0000-000000000001"
      }
    }
  }'
```