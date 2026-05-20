#!/usr/bin/env node
'use strict';

// Lumen ↔ GitHub Copilot bridge.
//
// Architecture: long-lived Node process spawned by `CopilotService`
// (Dart) over stdio JSON-RPC. ONE `CopilotClient` instance is cached
// per auth-signature and reused across every `chat_start` request —
// `client.start()` spawns the Copilot CLI as a child node process,
// so creating a fresh client per prompt would leak one CLI child
// per prompt (especially nasty during council runs with N parallel
// agents × M turns). Cached client + per-request `Session` keeps the
// child-process count at 1 per Lumen session.
//
// Lifecycle:
// - `chat_start` / `list_models` → `ensureClient(auth)` (cache hit or
//   new). The cached client lives until either (a) auth changes
//   (signature mismatch → evict + recreate) or (b) bridge shuts down.
// - Shutdown is triggered by stdin EOF (parent Lumen.exe died /
//   closed the pipe), `SIGTERM`, `SIGINT`, or `SIGBREAK` (Windows).
//   We then `forceStop()` the cached client so its CLI child is
//   reaped synchronously rather than orphaning.
//
// Do NOT add per-request `client.stop()` calls anywhere — the only
// stop sites are in `shutdownBridge()` and `ensureClient()`'s
// eviction branch.

const readline = require('readline');
const { CopilotClient, approveAll, defineTool } = require('@github/copilot-sdk');

const sessions = new Map();

let cachedClient = null;
let cachedAuthSignature = null;
let shuttingDown = false;

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function clientConfig(auth = {}) {
  const token = typeof auth.gitHubToken === 'string'
    ? auth.gitHubToken.trim()
    : (typeof auth.githubToken === 'string' ? auth.githubToken.trim() : '');
  if (token) {
    return {
      // 0.3.x docs use `gitHubToken`; 0.2.x used `githubToken`.
      // Supplying both keeps the bridge compatible across preview SDKs.
      gitHubToken: token,
      githubToken: token,
      useLoggedInUser: false
    };
  }
  return { useLoggedInUser: auth.useLoggedInUser !== false };
}

function authSignature(auth = {}) {
  const token = typeof auth.gitHubToken === 'string'
    ? auth.gitHubToken.trim()
    : (typeof auth.githubToken === 'string' ? auth.githubToken.trim() : '');
  const useLoggedIn = token ? false : (auth.useLoggedInUser !== false);
  return JSON.stringify({ token, useLoggedIn });
}

async function ensureClient(auth) {
  const sig = authSignature(auth);
  if (cachedClient && cachedAuthSignature === sig) {
    return cachedClient;
  }
  if (cachedClient) {
    const previous = cachedClient;
    cachedClient = null;
    cachedAuthSignature = null;
    try {
      await previous.stop();
    } catch {
      // Best-effort eviction; we already disowned the reference.
    }
  }
  const client = new CopilotClient(clientConfig(auth));
  await client.start();
  cachedClient = client;
  cachedAuthSignature = sig;
  return client;
}

async function shutdownBridge(reason) {
  if (shuttingDown) return;
  shuttingDown = true;

  for (const [requestId, session] of sessions) {
    try { await session.abort(); } catch {}
    try { await session.disconnect(); } catch {}
    // Best-effort notice so any pending Dart stream gets a final
    // sentinel rather than waiting forever for the next event.
    try { send({ type: 'cancelled', requestId, reason }); } catch {}
  }
  sessions.clear();

  if (cachedClient) {
    const client = cachedClient;
    cachedClient = null;
    cachedAuthSignature = null;
    try {
      // `forceStop` skips graceful CLI cleanup — appropriate when the
      // parent has already died (stdin EOF) and we just need the
      // child reaped. Falls back to `stop` on older SDK versions.
      if (typeof client.forceStop === 'function') {
        await client.forceStop();
      } else {
        await client.stop();
      }
    } catch {
      // Already stopped or already dead; nothing more we can do.
    }
  }
  process.exit(0);
}

function formatMessages(messages) {
  const lines = [];
  for (const message of Array.isArray(messages) ? messages : []) {
    const role = String(message.role || 'user').toUpperCase();
    const content = String(message.content || '');
    if (role === 'TOOL') {
      lines.push(`TOOL RESULT (${message.tool_name || message.tool_use_id || 'tool'}):\n${content}`);
      continue;
    }
    const toolUse = message.tool_use;
    if (role === 'ASSISTANT' && toolUse && typeof toolUse === 'object') {
      lines.push(`ASSISTANT:\n${content}`);
      lines.push(`ASSISTANT CALLED TOOL ${toolUse.name || ''} WITH ${JSON.stringify(toolUse.arguments || {})}`);
      continue;
    }
    lines.push(`${role}:\n${content}`);
  }
  return lines.join('\n\n');
}

function buildTools(requestId, tools) {
  if (!Array.isArray(tools) || tools.length === 0) return [];
  return tools.map((tool) => {
    const name = String(tool.name || tool.id || '').trim();
    const description = String(tool.description || '');
    const parameters = tool.parameters && typeof tool.parameters === 'object'
      ? tool.parameters
      : { type: 'object', properties: {} };
    return defineTool(name, {
      description,
      parameters,
      skipPermission: true,
      overridesBuiltInTool: true,
      handler: async (args) => {
        const toolCallId = `copilot-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
        send({
          type: 'tool_call',
          requestId,
          id: toolCallId,
          name,
          arguments: args || {}
        });
        return new Promise(() => {
          // Lumen owns tool execution. Dart aborts this SDK turn after it
          // receives the tool_call marker, then sends the tool result in
          // the next prompt iteration.
        });
      }
    });
  });
}

function effortFor(value) {
  if (value === 'low' || value === 'medium' || value === 'high' || value === 'xhigh') {
    return value;
  }
  return undefined;
}

async function handleListModels(message) {
  const client = await ensureClient(message.auth || {});
  if (typeof client.listModels !== 'function') {
    throw new Error('Installed @github/copilot-sdk does not expose client.listModels().');
  }
  const models = await client.listModels();
  if (!Array.isArray(models) || models.length === 0) {
    throw new Error('Copilot SDK returned no models for this account.');
  }
  const normalized = models.map((m) => ({
    id: m.id || m.name || String(m),
    name: m.name || m.id || String(m),
    capabilities: m.capabilities || m.supports || null
  }));
  send({ type: 'models', requestId: message.requestId, models: normalized });
}

async function handleChatStart(message) {
  const requestId = message.requestId;
  const client = await ensureClient(message.auth || {});

  const session = await client.createSession({
    model: message.model || 'gpt-5',
    streaming: true,
    reasoningEffort: effortFor(message.effort),
    tools: buildTools(requestId, message.tools),
    onPermissionRequest: approveAll
  });
  sessions.set(requestId, session);

  let emittedFinal = false;
  let sawDelta = false;
  let idleResolve;
  const idle = new Promise((resolve) => {
    idleResolve = resolve;
  });

  session.on('assistant.message_delta', (event) => {
    const text = event && event.data ? event.data.deltaContent || '' : '';
    if (text) {
      sawDelta = true;
      send({ type: 'delta', requestId, text });
    }
  });
  session.on('assistant.reasoning_delta', (event) => {
    const text = event && event.data ? event.data.deltaContent || '' : '';
    if (text) send({ type: 'thinking_delta', requestId, text });
  });
  session.on('assistant.message', (event) => {
    const text = event && event.data ? event.data.content || '' : '';
    if (text && !sawDelta) send({ type: 'delta', requestId, text });
    emittedFinal = true;
  });
  session.on('session.idle', () => idleResolve());

  try {
    await session.send({ prompt: formatMessages(message.messages) });
    await idle;
    send({ type: 'done', requestId, emittedFinal });
  } finally {
    sessions.delete(requestId);
    try {
      await session.disconnect();
    } catch {
      // Best effort.
    }
    // Intentionally NO `client.stop()` here. The client is shared
    // across every request for this auth-signature and only dies in
    // `shutdownBridge()` or on auth eviction inside `ensureClient`.
  }
}

async function handleCancel(message) {
  const requestId = message.requestId;
  const session = sessions.get(requestId);
  if (session) {
    try {
      await session.abort();
    } catch {
      // Best effort.
    }
    try {
      await session.disconnect();
    } catch {
      // Best effort.
    }
    sessions.delete(requestId);
  }
  // No `client.stop()` — see lifecycle note at top of file.
  send({ type: 'cancelled', requestId });
}

async function handleMessage(message) {
  try {
    if (message.type === 'list_models') {
      await handleListModels(message);
    } else if (message.type === 'chat_start') {
      await handleChatStart(message);
    } else if (message.type === 'cancel') {
      await handleCancel(message);
    } else {
      send({ type: 'error', requestId: message.requestId, error: `Unknown message type: ${message.type}` });
    }
  } catch (error) {
    send({
      type: 'error',
      requestId: message.requestId,
      error: error && error.message ? error.message : String(error)
    });
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    send({ type: 'error', error: `Invalid JSON: ${error.message}` });
    return;
  }
  handleMessage(message);
});

// Shutdown triggers. The critical one is `stdin end`: when the Dart
// side closes its end of the pipe (during `CopilotService.dispose`)
// we get an EOF here and can reap the cached CopilotClient + its
// CLI child before Lumen.exe exits. Without this, the child node
// orphans (Windows TerminateProcess on the bridge skips the SIGTERM
// handler and any cleanup wiring tied to it).
rl.on('close', () => shutdownBridge('stdin-close'));
process.stdin.on('end', () => shutdownBridge('stdin-end'));
process.on('SIGTERM', () => shutdownBridge('SIGTERM'));
process.on('SIGINT', () => shutdownBridge('SIGINT'));
process.on('SIGBREAK', () => shutdownBridge('SIGBREAK'));
process.on('SIGHUP', () => shutdownBridge('SIGHUP'));
