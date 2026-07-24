#!/bin/zsh
set -eu
cd "${0:A:h}/Backend"

# The double-click development launcher treats Backend/.env as the single source
# of truth. This prevents stale `export JARVIS_APP_TOKEN=...` values inherited
# from Terminal from silently enabling authentication and causing HTTP 401.
unset OPENAI_API_KEY OPENAI_MODEL JARVIS_APP_TOKEN JARVIS_WEB_SEARCH
unset PORT JARVIS_MAX_REQUEST_BYTES JARVIS_REQUESTS_PER_MINUTE

exec /usr/bin/env node server.mjs
