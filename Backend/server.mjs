import { createHash, timingSafeEqual } from "node:crypto";
import { once } from "node:events";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";

// Load Backend/.env without introducing a package dependency. Existing shell
// environment variables always win, so production secret injection still works.
loadEnvironmentFile(new URL(".env", import.meta.url));

const port = positiveNumber("PORT", 8787);
const apiKey = process.env.OPENAI_API_KEY?.trim() ?? "";
const model = process.env.OPENAI_MODEL?.trim() || "gpt-5.6-luna";
const appToken = process.env.JARVIS_APP_TOKEN?.trim() ?? "";
const enableWebSearch = booleanFromEnvironment("JARVIS_WEB_SEARCH", true);
const requestLimitBytes = positiveNumber("JARVIS_MAX_REQUEST_BYTES", 10 * 1024 * 1024);
const requestsPerMinute = positiveNumber("JARVIS_REQUESTS_PER_MINUTE", 30);
const rateBuckets = new Map();

const server = createServer(async (request, response) => {
  setCommonHeaders(response);
  const path = new URL(request.url ?? "/", "http://localhost").pathname;

  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }

  if (request.method === "GET" && path === "/health") {
    sendJSON(response, 200, {
      ok: true,
      service: "jarvis-ios-backend",
      model,
      webSearch: enableWebSearch,
      openAIConfigured: apiKey.length > 0,
      authenticationEnabled: appToken.length > 0,
    });
    return;
  }

  if (request.method !== "POST" || path !== "/answer") {
    sendJSON(response, 404, { error: "Not found" });
    return;
  }

  if (!authorized(request.headers.authorization)) {
    sendJSON(response, 401, { error: "Unauthorized" });
    return;
  }

  const clientAddress = request.socket.remoteAddress ?? "unknown";
  if (!consumeRateLimit(clientAddress)) {
    sendJSON(response, 429, { error: "Too many requests. Please retry in one minute." });
    return;
  }

  if (!apiKey) {
    sendJSON(response, 503, {
      error: "OPENAI_API_KEY is not configured",
      detail: "Open Backend/.env and add a server-side OpenAI API key, then restart the backend.",
    });
    return;
  }

  try {
    const body = await readJSON(request, requestLimitBytes);
    validate(body);

    const controller = new AbortController();
    response.on("close", () => {
      if (!response.writableEnded) controller.abort();
    });

    const upstreamPayload = {
      model,
      store: false,
      stream: true,
      safety_identifier: privacyHash(body.clientID),
      max_output_tokens: 1200,
      reasoning: { effort: "low" },
      text: { verbosity: "low" },
      instructions: [
        "你是运行在 iPhone 上的专业视觉识别助手 JARVIS。",
        "先直接回答用户的问题，再给最多三个真正有操作价值的要点。",
        "只能陈述当前照片和会话上下文能够支持的事实；看不清时明确说明，并建议靠近、补光或换角度。",
        "需要最新价格、规格、新闻或事实核查时使用联网搜索；使用搜索结果时保留来源引用。",
        "涉及医疗、电气、机械、化学品、交通或人身安全时，优先提示停止危险操作并咨询专业人员。",
        "默认用简洁自然的中文回答，避免冗长格式，方便手机语音播报。",
      ].join("\n"),
      input: [
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: contextText(body.question, body.conversationSummary),
            },
            {
              type: "input_image",
              image_url: `data:image/jpeg;base64,${body.imageBase64}`,
              detail: "high",
            },
          ],
        },
      ],
    };

    if (enableWebSearch) {
      upstreamPayload.tools = [{ type: "web_search", search_context_size: "low" }];
    }

    const upstream = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      signal: controller.signal,
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(upstreamPayload),
    });

    if (!upstream.ok || !upstream.body) {
      const detail = await upstream.text();
      sendJSON(response, upstream.status || 502, {
        error: "OpenAI request failed",
        detail: readableUpstreamError(detail),
      });
      return;
    }

    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });
    response.flushHeaders?.();

    const reader = upstream.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!response.write(Buffer.from(value))) {
        await once(response, "drain");
      }
    }
    response.end();
  } catch (error) {
    if (error?.name === "AbortError") return;
    const status = Number.isInteger(error?.status) ? error.status : 500;
    sendJSON(response, status, { error: error?.message ?? "Unexpected server error" });
  }
});

server.listen(port, "0.0.0.0", () => {
  console.log(`JARVIS iOS backend listening on http://0.0.0.0:${port}`);
  console.log(`Model: ${model} · web search: ${enableWebSearch ? "on" : "off"}`);
  console.log(`OpenAI key: ${apiKey ? "configured" : "missing"} · app token: ${appToken ? "enabled" : "disabled (local development only)"}`);
});

function loadEnvironmentFile(url) {
  let contents;
  try {
    contents = readFileSync(url, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }

  for (const originalLine of contents.split(/\r?\n/)) {
    const line = originalLine.trim().replace(/^export\s+/, "");
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) continue;

    const key = line.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) || process.env[key] !== undefined) continue;

    let value = line.slice(separator + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

function authorized(header = "") {
  if (!appToken) return true;
  const expected = Buffer.from(`Bearer ${appToken}`);
  const supplied = Buffer.from(header);
  return expected.length === supplied.length && timingSafeEqual(expected, supplied);
}

function consumeRateLimit(key) {
  const now = Date.now();
  const bucket = rateBuckets.get(key);
  if (!bucket || now - bucket.startedAt >= 60_000) {
    rateBuckets.set(key, { startedAt: now, count: 1 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= requestsPerMinute;
}

async function readJSON(request, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw statusError(413, "Request body is too large");
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw statusError(400, "Invalid JSON body");
  }
}

function validate(body) {
  if (!body || typeof body !== "object") throw statusError(400, "Missing JSON body");
  if (typeof body.question !== "string" || !body.question.trim()) throw statusError(400, "Missing question");
  if (body.question.length > 2000) throw statusError(400, "Question is too long");
  if (typeof body.imageBase64 !== "string" || body.imageBase64.length < 64) throw statusError(400, "Missing image");
  if (typeof body.clientID !== "string" || !body.clientID) throw statusError(400, "Missing clientID");
  if (typeof body.conversationSummary === "string" && body.conversationSummary.length > 4000) {
    throw statusError(400, "Conversation summary is too long");
  }
}

function contextText(question, summary) {
  const safeSummary = typeof summary === "string" ? summary.trim().slice(0, 4000) : "";
  return safeSummary
    ? `最近的对话（仅供理解追问）：\n${safeSummary}\n\n当前问题：${question.trim()}`
    : `当前问题：${question.trim()}`;
}

function privacyHash(value) {
  return createHash("sha256").update(value).digest("hex");
}

function readableUpstreamError(raw) {
  try {
    const parsed = JSON.parse(raw);
    return String(parsed?.error?.message ?? parsed?.error ?? raw).slice(0, 1200);
  } catch {
    return raw.slice(0, 1200);
  }
}

function statusError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function setCommonHeaders(response) {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
  response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  response.setHeader("X-Content-Type-Options", "nosniff");
}

function sendJSON(response, status, value) {
  if (response.headersSent) {
    response.end();
    return;
  }
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

function positiveNumber(name, fallback) {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function booleanFromEnvironment(name, fallback) {
  const value = process.env[name];
  if (value === undefined) return fallback;
  return !["false", "0", "no", "off"].includes(value.trim().toLowerCase());
}
