#!/usr/bin/env node
'use strict';

const readline = require('readline');
const { CopilotClient, approveAll, defineTool } = require('@github/copilot-sdk');

const clients = new Map();
const sessions = new Map();

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

async function createClient(auth) {
  const client = new CopilotClient(clientConfig(auth));
  await client.start();
  return client;
}

async function stopClient(key) {
  const client = clients.get(key);
  if (!client) return;
  clients.delete(key);
  try {
    await client.stop();
  } catch {
    // Best effort shutdown.
  }
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
  const client = await createClient(message.auth || {});
  try {
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
  } finally {
    await client.stop();
  }
}

async function handleChatStart(message) {
  const requestId = message.requestId;
  const client = await createClient(message.auth || {});
  clients.set(requestId, client);

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
    await stopClient(requestId);
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
  await stopClient(requestId);
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
    if (message.requestId) await stopClient(message.requestId);
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

process.on('SIGTERM', async () => {
  for (const key of Array.from(sessions.keys())) {
    await handleCancel({ requestId: key });
  }
  process.exit(0);
});
