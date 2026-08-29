# config/model-catalog.json

Model cost catalog for the standalone demo, referenced from `config.modelCatalog` in
`agentgateway_config.yaml`. The file itself takes no comments: `Catalog` is
`#[serde(deny_unknown_fields)]`, so even a `_comment` key makes the gateway refuse to load it.

- Model cost catalog for the standalone demo, referenced from config.modelCatalog.
- Rates are USD per 1,000,000 tokens, as decimal strings.

- Lookup is an EXACT match on (provider, model) -- there is no prefix or fuzzy matching
- (llm/catalog/model.rs resolve()). The gateway tries the provider-reported RESPONSE model
- first and falls back to the request model, so dated variants are listed alongside the
- plain names. Response models actually observed on these routes:
-   /openai, /policy/openai -> gpt-4o-2024-08-06
-   /anthropic              -> claude-sonnet-4-5-20250929
-   /gemini                 -> gemini-2.5-flash-lite

- Provider keys must match the gateway's own provider ids, not the vendor's branding:
- openai, anthropic, aws.bedrock, gcp.gemini, gcp.vertex_ai, azure, copilot, cohere
- (see MODELS_DEV_PROVIDER_IDS in llm/catalog/refresh.rs).

- Verify with: curl -s localhost:15020/metrics | grep cost_catalog_lookups
- A status="missing" increment means a model reached the gateway that is not listed here.
