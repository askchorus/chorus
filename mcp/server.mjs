#!/usr/bin/env node
// Chorus MCP server — lets a coding agent put a question to the AI panels open in Chorus and read
// every answer back. Talks to the running app over loopback; Chorus must be open, logged in, and
// have "Coding-agent access" enabled in Settings.
//
// Stdio JSON-RPC (MCP). Deliberately dependency-free so it runs anywhere node does.

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const PORT = 8765;

function token() {
  if (process.env.CHORUS_TOKEN) return process.env.CHORUS_TOKEN;
  try {
    return execFileSync("defaults", ["read", "com.smiletalker.chorus", "agentBridgeToken"], {
      encoding: "utf8",
    }).trim();
  } catch {
    return "";
  }
}

const TOOL = {
  name: "ask_other_ais",
  description:
    "Ask the AI web panels the user has open in Chorus (ChatGPT, Gemini, Claude, DeepSeek, Kimi… " +
    "whichever they're showing) and get every panel's full answer back. Use it for a genuine second " +
    "opinion on judgment calls, to check a claim against models with different training, or to " +
    "reach the live-search / deep-research modes those web UIs have. Answers come back raw and " +
    "unsummarized — where they DISAGREE is the useful part. Each call takes 30s–2min and is rate " +
    "limited to one question per 30 seconds, so use it deliberately, not in a loop.",
  inputSchema: {
    type: "object",
    properties: {
      prompt: {
        type: "string",
        description:
          "The question, self-contained. These AIs have no context from this session, so include " +
          "whatever background they need.",
      },
    },
    required: ["prompt"],
  },
};

async function ask(prompt) {
  const res = await fetch(`http://127.0.0.1:${PORT}/ask`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token()}` },
    body: JSON.stringify({ prompt }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const hint =
      res.status === 401 ? " (is 'Coding-agent access' enabled in Chorus → Settings?)"
      : res.status === 409 && /no AI panels/.test(body.error || "") ? " (no panels are open in Chorus)"
      : "";
    throw new Error(`${body.error || res.statusText}${hint}`);
  }
  return body.answers || [];
}

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function fail(id, message) {
  process.stdout.write(
    JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } }) + "\n"
  );
}

let buf = "";
process.stdin.on("data", async (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }

    if (msg.method === "initialize") {
      reply(msg.id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "chorus", version: "0.1.0" },
      });
    } else if (msg.method === "tools/list") {
      reply(msg.id, { tools: [TOOL] });
    } else if (msg.method === "tools/call") {
      const { name, arguments: args } = msg.params || {};
      if (name !== TOOL.name) { fail(msg.id, `unknown tool: ${name}`); continue; }
      try {
        const answers = await ask(args?.prompt || "");
        const text = answers.length
          ? answers.map((a) => `## ${a.name}\n\n${a.text}`).join("\n\n---\n\n")
          : "No panel produced an answer.";
        reply(msg.id, { content: [{ type: "text", text }] });
      } catch (e) {
        fail(msg.id, `Chorus: ${e.message}`);
      }
    } else if (msg.id !== undefined) {
      reply(msg.id, {});
    }
  }
});
