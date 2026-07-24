# JARVIS iOS Backend

A zero-dependency Node.js 20+ service that keeps the OpenAI API key off the iPhone, validates visual-assistant requests, and streams Responses API events back to the app over Server-Sent Events.

## Start locally

From the repository root:

```bash
cp Backend/.env.example Backend/.env
```

Add a server-side API key to `Backend/.env`, then run:

```bash
node Backend/server.mjs
```

Check service readiness:

```bash
curl http://127.0.0.1:8787/health
```

Real visual responses are available only when `openAIConfigured` is `true`. Without a key, the service still starts and reports health, while `POST /answer` returns an explicit HTTP 503 configuration error.

## Configuration

```dotenv
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna
JARVIS_APP_TOKEN=
JARVIS_WEB_SEARCH=true
PORT=8787
JARVIS_MAX_REQUEST_BYTES=10485760
JARVIS_REQUESTS_PER_MINUTE=30
```

The real `.env` file is excluded by both the repository and backend `.gitignore` files. Do not commit it.

`JARVIS_APP_TOKEN` is optional only for trusted local development. If enabled, the iOS client must send the same value as a bearer token. A public deployment also requires HTTPS, managed secrets, durable rate limiting, restricted CORS, and production-grade authentication and monitoring.

See the repository-level README for the complete app setup, API contract, and troubleshooting guide.
