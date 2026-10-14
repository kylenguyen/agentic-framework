#!/usr/bin/env node
// tests/mcp-probe.mjs: talk to a stdio MCP server the way a harness does, without a harness.
// Usage: node tests/mcp-probe.mjs [--call <tool> '<json args>']... -- <command> [args...]
// Sends initialize, notifications/initialized and tools/list, then each --call in order, and prints one JSON line
// per response: {"tools": [...names]} then {"call": name, "isError": bool, "text": "...", "images": n}.
// Exits 1 on a protocol error or timeout (PROBE_TIMEOUT_MS, default 120000 per request). With PROBE_IMAGE_DIR set,
// every image a call returns is written there as <call>-<n>.<ext>, to look at what the agent would see.
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const calls = [];
while (argv.length && argv[0] !== "--") {
  const flag = argv.shift();
  if (flag !== "--call") { console.error(`unknown option ${flag}`); process.exit(2); }
  calls.push({ name: argv.shift(), args: JSON.parse(argv.shift() || "{}") });
}
argv.shift();
if (!argv.length) { console.error("usage: mcp-probe.mjs [--call tool json]... -- command [args...]"); process.exit(2); }

const timeoutMs = Number(process.env.PROBE_TIMEOUT_MS || 120000);
const child = spawn(argv[0], argv.slice(1), { stdio: ["pipe", "pipe", "inherit"] });
let buf = "", nextId = 1;
const pending = new Map();
child.stdout.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { console.error(`non-JSON on stdout: ${line.slice(0, 200)}`); process.exit(1); }
    if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  }
});
child.on("exit", (code) => { if (pending.size) { console.error(`server exited (${code}) with requests pending`); process.exit(1); } });

function request(method, params) {
  const id = nextId++;
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`${method}: no answer in ${timeoutMs} ms`)), timeoutMs);
    pending.set(id, (m) => { clearTimeout(t); m.error ? reject(new Error(`${method}: ${JSON.stringify(m.error)}`)) : resolve(m.result); });
  });
}

try {
  await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "mcp-probe", version: "1" } });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const { tools } = await request("tools/list", {});
  console.log(JSON.stringify({ tools: tools.map((t) => t.name) }));
  for (const c of calls) {
    const r = await request("tools/call", { name: c.name, arguments: c.args });
    const text = (r.content || []).filter((x) => x.type === "text").map((x) => x.text).join("\n");
    const imgs = (r.content || []).filter((x) => x.type === "image");
    if (process.env.PROBE_IMAGE_DIR) imgs.forEach((x, i) => writeFileSync(
      `${process.env.PROBE_IMAGE_DIR}/${c.name}-${i}.${(x.mimeType || "image/png").split("/")[1]}`, Buffer.from(x.data, "base64")));
    const images = imgs.length;
    console.log(JSON.stringify({ call: c.name, isError: !!r.isError, text: text.slice(0, 4000), images }));
  }
  child.stdin.end(); child.kill();
  process.exit(0);
} catch (e) {
  console.error(e.message); child.kill(); process.exit(1);
}
