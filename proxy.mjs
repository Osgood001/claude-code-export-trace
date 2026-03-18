#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════
//  Catcher in the Rye — Claude Code API Proxy with Full Trace Capture
//  Zero dependencies. Node.js 18+ only.
// ═══════════════════════════════════════════════════════════════════════════
import { createServer } from "http";
import { request as httpsRequest } from "https";
import { mkdirSync, appendFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// ── Configuration (all via env vars) ─────────────────────────────────────
const PORT       = parseInt(process.env.CATCHER_PORT || "18080", 10);
const TARGET     = process.env.CATCHER_TARGET || "api.gpugeek.com";
const API_KEY    = process.env.CATCHER_API_KEY || "";
const AUTH_MODE  = process.env.CATCHER_AUTH_MODE || "x-api-key"; // "x-api-key" | "bearer" | "none"
const TRACE_DIR  = process.env.CATCHER_TRACE_DIR || join(homedir(), ".claude", "traces");

// Model name mapping: Claude Code model IDs → provider model IDs
// Override via CATCHER_MODEL_MAP='{"claude-opus-4-6":"some/model"}'
const DEFAULT_MODEL_MAP = {
  "claude-opus-4-6":           "Vendor2/Claude-4.6-opus",
  "claude-sonnet-4-6":         "Vendor2/Claude-4.5-Sonnet",
  "claude-haiku-4-5-20251001": "Vendor2/Claude-4.5-Sonnet",
};
let MODEL_MAP = DEFAULT_MODEL_MAP;
if (process.env.CATCHER_MODEL_MAP) {
  try { MODEL_MAP = { ...DEFAULT_MODEL_MAP, ...JSON.parse(process.env.CATCHER_MODEL_MAP) }; }
  catch (e) { console.error("WARN: Failed to parse CATCHER_MODEL_MAP, using defaults"); }
}

// ── Trace logging ────────────────────────────────────────────────────────
mkdirSync(TRACE_DIR, { recursive: true });

function traceFile() {
  return join(TRACE_DIR, `${new Date().toISOString().slice(0, 10)}.jsonl`);
}

let _seq = 0;
function writeTrace(record) {
  record._seq = _seq++;
  record._ts = new Date().toISOString();
  try {
    appendFileSync(traceFile(), JSON.stringify(record) + "\n");
  } catch (e) {
    console.error("trace write error:", e.message);
  }
}

// ── Model rewriting ──────────────────────────────────────────────────────
function rewriteModel(bodyBuf) {
  try {
    const json = JSON.parse(bodyBuf.toString());
    const orig = json.model;
    if (json.model && MODEL_MAP[json.model]) {
      json.model = MODEL_MAP[json.model];
    }
    return { buf: Buffer.from(JSON.stringify(json)), parsed: json, origModel: orig };
  } catch {
    return { buf: bodyBuf, parsed: null, origModel: null };
  }
}

// ── SSE stream parsing & assembly ────────────────────────────────────────
function parseSSEChunks(raw) {
  const text = raw.toString("utf-8");
  const events = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("data: ")) {
      const payload = line.slice(6).trim();
      if (payload && payload !== "[DONE]") {
        try { events.push(JSON.parse(payload)); } catch {}
      }
    }
  }
  return events;
}

function assembleResponse(events) {
  if (!events.length) return null;
  const msgStart = events.find(e => e.type === "message_start");
  const base = msgStart?.message || {};
  const blocks = [];
  let currentBlock = null;

  for (const ev of events) {
    if (ev.type === "content_block_start") {
      currentBlock = { ...ev.content_block, _parts: [] };
    } else if (ev.type === "content_block_delta" && currentBlock && ev.delta) {
      const d = ev.delta;
      if (d.type === "text_delta")        currentBlock._parts.push(d.text || "");
      else if (d.type === "thinking_delta") currentBlock._parts.push(d.thinking || "");
      else if (d.type === "input_json_delta") currentBlock._parts.push(d.partial_json || "");
      else if (d.type === "signature_delta") currentBlock.signature = (currentBlock.signature || "") + (d.signature || "");
    } else if (ev.type === "content_block_stop" && currentBlock) {
      const joined = currentBlock._parts.join("");
      if (currentBlock.type === "text")        currentBlock.text = joined;
      else if (currentBlock.type === "thinking") currentBlock.thinking = joined;
      else if (currentBlock.type === "tool_use") {
        try { currentBlock.input = JSON.parse(joined); } catch { currentBlock.input_raw = joined; }
      }
      delete currentBlock._parts;
      blocks.push(currentBlock);
      currentBlock = null;
    }
  }

  const msgDelta = events.filter(e => e.type === "message_delta").pop();
  return {
    id: base.id,
    type: base.type || "message",
    role: base.role || "assistant",
    model: base.model,
    stop_reason: msgDelta?.delta?.stop_reason || base.stop_reason,
    content: blocks,
    usage: { ...(base.usage || {}), ...(msgDelta?.usage || {}) },
  };
}

// ── HTTP Server ──────────────────────────────────────────────────────────
createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body = Buffer.concat(chunks);
    console.log(`${new Date().toISOString()} ${req.method} ${req.url}`);

    // Rewrite model
    const { buf: rewritten, parsed: reqJson, origModel } = rewriteModel(body);
    body = rewritten;
    if (origModel && MODEL_MAP[origModel]) {
      console.log(`  model: ${origModel} → ${MODEL_MAP[origModel]}`);
    }

    // Session fingerprint: first user message content (stable per session)
    let sessionHint = null;
    if (reqJson?.messages?.length) {
      const first = reqJson.messages.find(m => m.role === "user");
      if (first) {
        const c = typeof first.content === "string" ? first.content : JSON.stringify(first.content);
        sessionHint = c.slice(0, 64);
      }
    }

    // Trace request
    const reqId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    writeTrace({
      type: "request",
      reqId,
      method: req.method,
      path: req.url,
      origModel,
      sessionHint,
      numMessages: reqJson?.messages?.length || 0,
      numTools: reqJson?.tools?.length || 0,
      hasSystem: !!(reqJson?.system),
      body: reqJson,
    });

    // Build upstream headers
    const headers = { ...req.headers };
    delete headers["authorization"];
    delete headers["host"];
    headers["host"] = TARGET;
    headers["content-length"] = body.length;
    if (AUTH_MODE === "x-api-key") {
      headers["x-api-key"] = API_KEY;
    } else if (AUTH_MODE === "bearer") {
      headers["authorization"] = `Bearer ${API_KEY}`;
    }
    // AUTH_MODE === "none": no auth header added

    const proxy = httpsRequest(
      { hostname: TARGET, port: 443, path: req.url, method: req.method, headers },
      (upstream) => {
        console.log(`  → ${upstream.statusCode}`);
        res.writeHead(upstream.statusCode, upstream.headers);

        // Tee: stream to client AND buffer for trace
        const respChunks = [];
        upstream.on("data", (chunk) => {
          respChunks.push(chunk);
          res.write(chunk);
        });
        upstream.on("end", () => {
          res.end();
          const respBuf = Buffer.concat(respChunks);
          const contentType = upstream.headers["content-type"] || "";
          let respData;
          if (contentType.includes("text/event-stream")) {
            const events = parseSSEChunks(respBuf);
            respData = {
              assembled: assembleResponse(events),
              event_count: events.length,
              raw_bytes: respBuf.length,
            };
          } else {
            try { respData = JSON.parse(respBuf.toString()); }
            catch { respData = { raw: respBuf.toString().slice(0, 10000) }; }
          }
          writeTrace({
            type: "response",
            reqId,
            status: upstream.statusCode,
            contentType,
            body: respData,
          });
        });
      }
    );
    proxy.on("error", (e) => {
      console.error(`  ERR: ${e.message}`);
      writeTrace({ type: "error", reqId, error: e.message });
      res.writeHead(502);
      res.end(`Proxy error: ${e.message}`);
    });
    proxy.end(body);
  });
}).listen(PORT, "127.0.0.1", () => {
  console.log(`╔══════════════════════════════════════════════════╗`);
  console.log(`║  Catcher in the Rye — Claude Code Trace Proxy   ║`);
  console.log(`╚══════════════════════════════════════════════════╝`);
  console.log(`  Listening : http://127.0.0.1:${PORT}`);
  console.log(`  Target    : ${TARGET}`);
  console.log(`  Auth mode : ${AUTH_MODE}`);
  console.log(`  Traces    : ${TRACE_DIR}/YYYY-MM-DD.jsonl`);
  console.log(`  Models    : ${Object.keys(MODEL_MAP).length} mappings`);
  console.log();
});
