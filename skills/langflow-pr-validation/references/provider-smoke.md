# Provider smoke test (only when Alice asks)

ChatInput → Agent → ChatOutput once per configured provider, against the running slot
(`$BASE=http://localhost:$PORT`). Flow: `${SKILL_DIR}/assets/basic-test-flow.json`. Secrets:
`set -a; source ${SKILL_DIR}/config/provider-secrets.env; set +a`.

| Provider (exact name) | Global variables to create | Model (mini tier only) | `model_class` |
|---|---|---|---|
| `OpenAI` | `OPENAI_API_KEY` (Credential) | a `gpt-*-mini` from `GET /api/v1/models` | `ChatOpenAI` |
| `Anthropic` | `ANTHROPIC_API_KEY` (Credential) | `claude-haiku-4-5-20251001` | `ChatAnthropic` |
| `Google Generative AI` | `GOOGLE_API_KEY` (Credential; the secrets file calls it `LANGFLOW_GOOGLE_API_KEY`) | `gemini-2.5-flash` | `ChatGoogleGenerativeAIFixed` |
| `IBM WatsonX` | `WATSONX_APIKEY` (no underscore; from `WATSONX_API_KEY`), `WATSONX_PROJECT_ID`, `WATSONX_URL` (Generic) | `ibm/granite-4-h-small` | `ChatWatsonx` |
| `Ollama` | `OLLAMA_BASE_URL` (Generic) | a model listed by `curl localhost:11434/api/tags` | `ChatOllama` |

Steps: token (`GET /api/v1/auto_login`) → API key (`POST /api/v1/api_key/`) → variables
(`POST /api/v1/variables/`, `default_fields: ["api_key"]` for keys) → delete leftover
`Smoke Test - *` flows → per provider: load the flow JSON, drop `id/user_id/folder_id/updated_at`,
set `name = "Smoke Test - <provider>"`, replace the Agent node's `template.model.value` with one
dict `{category, icon, provider, name, metadata:{api_key_param:"api_key", context_length,
max_tokens_field_name:"max_tokens", model_class, model_name_param:"model"}}` (omit
`api_key_param` entirely for Ollama — `None` breaks the Agent), set `template.api_key.value` to
the variable name → `POST /api/v1/flows/` → `POST /api/v1/run/<id>?stream=false` with
`x-api-key`, body `{"input_value":"Say hello in one short sentence.","output_type":"chat","input_type":"chat"}`,
`--max-time 90`. Success text at `outputs[0].outputs[0].results.message.text`; error in `detail`.

Report one table: Provider | Model | PASS/FAIL/SKIP | duration | note. WatsonX
`consumption_limit_reached` = quota, not a product bug. Ollama absent → SKIP.
