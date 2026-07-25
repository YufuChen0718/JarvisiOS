// Voicebox LAN bridge — run this on the same Mac that runs Voicebox.
//
// Why: Voicebox listens on 127.0.0.1 (localhost only), so your iPhone can't
// reach it directly. This tiny zero-dependency server listens on 0.0.0.0 (the
// whole LAN), forwards requests to Voicebox on 127.0.0.1, resolves whatever
// Voicebox returns into raw audio, and returns it synchronously — exactly what
// the JARVIS app expects. Voicebox 0.5.x requires a profile ID and exposes raw
// WAV output at /generate/stream; this bridge also accepts a profile name.
//
// Run:   node voicebox-bridge.mjs
// Then in the app, set the Voicebox URL to:  http://<your-Mac-IP>:8790/generate
//
// Optional env vars:
//   VOICEBOX_URL   default http://127.0.0.1:17493
//   PORT           default 8790
//   PROFILE        default profile id/name if the app doesn't send one

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const VOICEBOX = (process.env.VOICEBOX_URL ?? "http://127.0.0.1:17493").replace(/\/$/, "");
const PORT = Number(process.env.PORT ?? 8790);
const DEFAULT_PROFILE = process.env.PROFILE ?? "";
const PROFILE_CACHE_MS = 30_000;
let profileCache = { expiresAt: 0, profiles: [] };

const server = createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

  if (req.method === "GET" && req.url === "/health") {
    sendJSON(res, 200, { ok: true, voicebox: VOICEBOX });
    return;
  }
  if (req.method !== "POST") { sendJSON(res, 404, { error: "POST /generate" }); return; }

  try {
    const body = await readBody(req);
    const input = body ? JSON.parse(body) : {};
    const text = input.text ?? "";
    const requestedProfile = input.profile || input.profile_id || DEFAULT_PROFILE;
    if (!text) { sendJSON(res, 400, { error: "missing text" }); return; }

    const resolvedProfile = await resolveProfile(requestedProfile);
    if (!resolvedProfile) {
      const profiles = await loadProfiles();
      sendJSON(res, 400, {
        error: requestedProfile
          ? `Voicebox profile not found: ${requestedProfile}`
          : "Voicebox has no voice profiles",
        availableProfiles: profiles.map(({ id, name }) => ({ id, name })),
      });
      return;
    }

    console.log(
      `[bridge] generate: "${text.slice(0, 40)}..." profile=${resolvedProfile.name} (${resolvedProfile.id})`,
    );

    const payload = {
      profile_id: resolvedProfile.id,
      text,
      language: input.language ?? resolvedProfile.language ?? "zh",
    };

    const vbRes = await fetch(`${VOICEBOX}/generate/stream`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "audio/wav, audio/*, application/json" },
      body: JSON.stringify(payload),
    });

    if (!vbRes.ok) {
      const detail = await vbRes.text();
      console.log(`[bridge] Voicebox ${vbRes.status}: ${detail.slice(0, 300)}`);
      sendJSON(res, 502, { error: `Voicebox ${vbRes.status}`, detail: detail.slice(0, 500) });
      return;
    }

    const ctype = (vbRes.headers.get("content-type") ?? "").toLowerCase();

    if (ctype.includes("audio") || ctype.includes("octet-stream")) {
      const buf = Buffer.from(await vbRes.arrayBuffer());
      return sendAudio(res, buf, ctype);
    }

    const json = await vbRes.json();
    console.log(`[bridge] Voicebox JSON: ${JSON.stringify(json).slice(0, 400)}`);
    const found = findAudio(json);

    if (found?.type === "url") {
      const audioRes = await fetch(found.value);
      const buf = Buffer.from(await audioRes.arrayBuffer());
      return sendAudio(res, buf, audioRes.headers.get("content-type") ?? "audio/wav");
    }
    if (found?.type === "path" && existsSync(found.value)) {
      const buf = await readFile(found.value);
      return sendAudio(res, buf, mimeFromPath(found.value));
    }

    console.log("[bridge] could not locate audio in Voicebox response");
    sendJSON(res, 502, {
      error: "Voicebox 未同步返回音频。请把这段 JSON 发给助手以适配。",
      voiceboxResponse: json,
    });
  } catch (err) {
    console.error("[bridge] error:", err);
    sendJSON(res, 500, { error: String(err?.message ?? err) });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Voicebox bridge on http://0.0.0.0:${PORT}  ->  ${VOICEBOX}`);
  console.log(`In the app set Voicebox URL to: http://<your-Mac-IP>:${PORT}/generate`);
});

async function loadProfiles() {
  const now = Date.now();
  if (profileCache.expiresAt > now) return profileCache.profiles;

  const response = await fetch(`${VOICEBOX}/profiles`, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Cannot list Voicebox profiles (HTTP ${response.status}): ${detail.slice(0, 300)}`);
  }
  const profiles = await response.json();
  if (!Array.isArray(profiles)) throw new Error("Voicebox /profiles returned an invalid response");
  profileCache = { expiresAt: now + PROFILE_CACHE_MS, profiles };
  return profiles;
}

async function resolveProfile(requested) {
  const profiles = await loadProfiles();
  if (!profiles.length) return null;
  const value = String(requested ?? "").trim();
  if (!value) return profiles[0];
  const normalized = value.toLocaleLowerCase();
  return profiles.find((profile) => profile.id === value)
    ?? profiles.find((profile) => String(profile.name ?? "").toLocaleLowerCase() === normalized)
    ?? null;
}

function findAudio(obj) {
  const audioExt = /\.(wav|mp3|m4a|aac|ogg|flac)(\?|$)/i;
  const stack = [obj];
  while (stack.length) {
    const cur = stack.pop();
    if (typeof cur === "string") {
      if (/^https?:\/\//i.test(cur) && audioExt.test(cur)) return { type: "url", value: cur };
      if (audioExt.test(cur) && (cur.startsWith("/") || cur.startsWith("file:"))) {
        return { type: "path", value: cur.replace(/^file:\/\//, "") };
      }
    } else if (Array.isArray(cur)) {
      for (const v of cur) stack.push(v);
    } else if (cur && typeof cur === "object") {
      for (const v of Object.values(cur)) stack.push(v);
    }
  }
  return null;
}

function mimeFromPath(p) {
  const e = p.split(".").pop().toLowerCase();
  return { wav: "audio/wav", mp3: "audio/mpeg", m4a: "audio/mp4", aac: "audio/mp4", ogg: "audio/ogg", flac: "audio/flac" }[e] ?? "audio/wav";
}

function sendAudio(res, buf, ctype) {
  res.writeHead(200, { "Content-Type": ctype || "audio/wav", "Content-Length": buf.length });
  res.end(buf);
  console.log(`[bridge] returned ${buf.length} bytes (${ctype})`);
}

function sendJSON(res, status, obj) {
  const s = JSON.stringify(obj);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(s);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}
