/* eslint-disable no-undef */

/* ────────────────────────────────────────────────────────────────
   Lumen Remote — phone-first PWA client.

   Vanilla JS, no framework. Single-file because the whole client
   fits in ~700 lines and a build step would just slow down "fix it
   on the desktop, refresh on the phone" iteration. If this grows
   past ~1200 lines split into per-screen modules and add a tiny
   bundler.

   Architecture:
     - state         : module-level mutable singleton.
     - api(path)     : fetch with bearer header + 401 self-revoke.
     - ws            : single WebSocket, auto-reconnect, dispatches
                       semantic events into screen handlers.
     - render*()     : pure-ish DOM builders. Re-render on data
                       change EXCEPT inside the chat screen, which
                       updates specific bubble nodes for streaming
                       to keep deltas at 60fps.
     - hash-router   : window.location.hash drives which screen
                       renders. Keeps history + back-button working.
   ──────────────────────────────────────────────────────────────── */

const $ = (sel, ctx = document) => ctx.querySelector(sel);
const $$ = (sel, ctx = document) => Array.from(ctx.querySelectorAll(sel));
const el = (tag, props = {}, children = []) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') n.className = v;
    else if (k === 'dataset') Object.assign(n.dataset, v);
    else if (k.startsWith('on')) n.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'html') n.innerHTML = v;
    else n.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    if (c == null) continue;
    n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return n;
};

/* ── State ─────────────────────────────────────────────────── */

const TOKEN_KEY = 'lumen.token';
const DEVICE_KEY = 'lumen.device';

const state = {
  baseUrl: window.location.origin,
  token: localStorage.getItem(TOKEN_KEY),
  device: safeJSONParse(localStorage.getItem(DEVICE_KEY)),
  ws: null,
  wsBackoff: 1000,
  connection: 'disconnected', // 'connecting' | 'connected' | 'disconnected'
  // Live derived state from /v1/stream events:
  isGenerating: false,
  currentSessionId: null,
  currentWorkspace: null,
  // Cache of the last-fetched payloads. Avoids spinning while
  // navigating between screens.
  projects: null,
  projectChats: new Map(),       // projectId -> chats[]
  chatById: new Map(),           // chatId -> full ChatSession
  // Per-screen DOM handles for streaming updates.
  ui: {
    chatScreen: null,            // currently-rendered chat-screen root
  },
};

function safeJSONParse(s) { try { return JSON.parse(s); } catch (_) { return null; } }

/* ── Viewport handling for iOS Safari URL bar ─────────────── */

function setVH() {
  // Use innerHeight rather than 100vh so the keyboard / URL bar
  // dance doesn't push the composer off-screen. CSS reads
  // `--vh` and computes height as `calc(var(--vh) * 100)`.
  document.documentElement.style.setProperty(
    '--vh', `${window.innerHeight * 0.01}px`
  );
}
window.addEventListener('resize', setVH);
window.addEventListener('orientationchange', setVH);
setVH();

/* ── HTTP client ───────────────────────────────────────────── */

async function api(path, opts = {}) {
  const headers = { 'content-type': 'application/json', ...(opts.headers || {}) };
  if (state.token) headers.authorization = `Bearer ${state.token}`;
  const res = await fetch(state.baseUrl + path, { ...opts, headers });
  if (res.status === 401) {
    // Token revoked or never valid — bounce back to pairing.
    // Clear stored creds so the pair screen renders cleanly.
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(DEVICE_KEY);
    state.token = null;
    state.device = null;
    closeWS();
    location.hash = '#/pair';
    throw new Error('unauthorized');
  }
  return res;
}

async function apiJSON(path, opts = {}) {
  const res = await api(path, opts);
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch (_) { /* keep null */ }
  if (!res.ok) {
    const err = new Error(body?.error || `http_${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

/* ── WebSocket: single live connection ─────────────────────── */

function openWS() {
  if (!state.token) return;
  if (state.ws && state.ws.readyState <= 1) return;
  state.connection = 'connecting';
  refreshConnectionDot();

  const wsBase = state.baseUrl.replace(/^http/, 'ws');
  const url = `${wsBase}/v1/stream?token=${encodeURIComponent(state.token)}`;
  const ws = new WebSocket(url);

  ws.addEventListener('open', () => {
    state.wsBackoff = 1000;
    state.connection = 'connected';
    refreshConnectionDot();
  });
  ws.addEventListener('message', (ev) => {
    try { handleEvent(JSON.parse(ev.data)); }
    catch (_) { /* malformed frame; drop quietly */ }
  });
  ws.addEventListener('close', () => {
    state.ws = null;
    state.connection = 'disconnected';
    refreshConnectionDot();
    if (!state.token) return;
    // Cap backoff at 15s — phones flap a lot when waking from
    // standby and we don't want to hammer the desktop.
    setTimeout(openWS, state.wsBackoff);
    state.wsBackoff = Math.min(state.wsBackoff * 1.6, 15000);
  });
  ws.addEventListener('error', () => { /* close handler covers cleanup */ });
  state.ws = ws;
}

function closeWS() {
  if (state.ws) {
    try { state.ws.close(); } catch (_) { /* already closed */ }
  }
  state.ws = null;
}

function refreshConnectionDot() {
  const dot = $('.header__connection');
  if (!dot) return;
  dot.classList.remove('is-connected', 'is-connecting');
  if (state.connection === 'connected') dot.classList.add('is-connected');
  if (state.connection === 'connecting') dot.classList.add('is-connecting');
}

/* ── Event dispatch ────────────────────────────────────────── */

function handleEvent(e) {
  switch (e.kind) {
    case 'connected':
      // No-op other than the open handler already setting state.
      // Could surface clientCount in the header tooltip later.
      break;
    case 'state_changed':
      state.isGenerating = !!e.isGenerating;
      state.currentSessionId = e.currentSessionId || null;
      state.currentWorkspace = e.currentWorkspace || null;
      // If the chat screen is rendered for the active chat, update
      // its thinking indicator + composer.
      if (state.ui.chatScreen?.dataset?.chatId === state.currentSessionId) {
        updateChatThinkingState();
      }
      break;
    case 'chats_replaced':
      // Whole list refreshed; invalidate the cached map. If we're
      // on the chats screen, re-fetch.
      state.projectChats.clear();
      if (location.hash.startsWith('#/projects/')) route();
      break;
    case 'chat_created':
      // Insert into the cache for the chat's workspace; refresh if
      // we're on the matching chats screen.
      if (e.chat?.workspacePath) {
        invalidateProjectChats();
        if (location.hash.startsWith('#/projects/')) route();
      }
      break;
    case 'chat_updated':
      invalidateProjectChats();
      // If we have the full session cached, patch its title/updatedAt
      // so the chat-screen header re-renders next paint.
      if (state.chatById.has(e.chatId)) {
        const c = state.chatById.get(e.chatId);
        c.title = e.title;
        c.updatedAt = e.updatedAt;
        c.model = e.model;
        if (state.ui.chatScreen?.dataset?.chatId === e.chatId) {
          const t = state.ui.chatScreen.querySelector('.header__title');
          if (t) t.textContent = c.title;
          // Keep the model pill in sync when the desktop changes
          // model out from under us (e.g. user picks model in the
          // desktop composer while the phone is on the same chat).
          const pillLabel = state.ui.chatScreen.querySelector('.model-pill__label');
          if (pillLabel && e.model) pillLabel.textContent = modelLabel(e.model);
        }
      }
      if (location.hash.startsWith('#/projects/')) route();
      break;
    case 'chat_deleted':
      invalidateProjectChats();
      state.chatById.delete(e.chatId);
      // If we're sitting on the deleted chat, bail back to the
      // chats list. Without this the screen stays open against
      // a session that no longer exists.
      const m = location.hash.match(/^#\/chats\/([^/]+)/);
      if (m && m[1] === e.chatId) history.back();
      else if (location.hash.startsWith('#/projects/')) route();
      break;
    case 'message_added':
      onMessageAdded(e.chatId, e.message);
      break;
    case 'message_delta':
      onMessageDelta(e.chatId, e.messageId, e.content);
      break;
    case 'message_complete':
      onMessageComplete(e.chatId, e.messageId);
      break;
    case 'message_deleted':
      onMessageDeleted(e.chatId, e.messageId);
      break;
    default:
      // Forward-compatible: ignore unknown kinds. Server may
      // ship new events in a future PR.
      break;
  }
}

function invalidateProjectChats() {
  state.projectChats.clear();
}

/* ── Router ────────────────────────────────────────────────── */

window.addEventListener('hashchange', route);
window.addEventListener('DOMContentLoaded', () => {
  if (state.token) openWS();
  route();
});

function route() {
  if (!state.token) return renderPair();
  const h = location.hash.slice(1) || '/';
  if (h === '/' || h === '/projects') return renderProjects();
  let m;
  if ((m = h.match(/^\/projects\/([^/]+)$/))) return renderChats(m[1]);
  if ((m = h.match(/^\/chats\/([^/]+)$/))) return renderChat(m[1]);
  // Unknown route — go home.
  location.hash = '#/projects';
}

/* ── Helpers ───────────────────────────────────────────────── */

function svgIcon(name) {
  const paths = {
    back: 'M15 18l-6-6 6-6',
    plus: 'M12 5v14M5 12h14',
    send: 'M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z',
    stop: 'M6 6h12v12H6z',
    folder: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
    chat: 'M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z',
    expand: 'M3 8V3h5M21 8V3h-5M3 16v5h5M21 16v5h-5',
    collapse: 'M8 3v5H3M16 3v5h5M8 21v-5H3M16 21v-5h5',
  };
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', '18');
  svg.setAttribute('height', '18');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', paths[name]);
  svg.appendChild(p);
  return svg;
}

function relativeTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60) return `${Math.floor(diff)}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 604800) return `${Math.floor(diff / 86400)}d ago`;
  return d.toISOString().split('T')[0];
}

let toastTimer;
function toast(msg) {
  let n = $('.toast');
  if (!n) {
    n = el('div', { class: 'toast' });
    document.body.appendChild(n);
  }
  n.textContent = msg;
  n.classList.add('is-shown');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => n.classList.remove('is-shown'), 1800);
}

/* Tiny markdown -> HTML. Handles fenced code, inline code, bold,
   italic, headers, plus Lumen's tool-call / thinking / provider-error
   markers. Deliberately conservative — anything ambiguous renders as
   plain text.

   Marker families this understands (all desktop-side parsers in
   `lib/widgets/ai_chat/tool_segments.dart`, kept in sync here):

     1. `<!-- LUMEN_TOOL:id|percent-encoded-arg|status -->`
        Status: ok | err | pending | malformed. Rendered as a pill.
     2. `<!-- LUMEN_THINKING [active] -->\n…content…\n<!-- /LUMEN_THINKING -->`
        Reasoning trace; `active` means still streaming. Rendered as
        a collapsible <details>; open while active, collapsed once
        complete.
     3. `<!-- LUMEN_ERR:kind|percent-encoded-detail -->`
        Provider error. Rendered as an inline error chip.
     4. `<!-- LUMEN_THINK_START -->` / `<!-- LUMEN_THINK_END -->`
        Stream-internal markers from OllamaService. Should never
        reach a persisted message but we strip them defensively in
        case the desktop ships them through.

   Additionally: raw tool-call body syntax (`<<<CREATE_FILE: x>>>…
   <<<END_FILE>>>` and friends) only appears in the live content while
   the model is mid-stream — once execution finishes the desktop
   swaps it for a LUMEN_TOOL marker. To avoid dumping the file body
   into the chat during that window we run a JS port of the
   desktop's `streamingToolPreview` (same conversion to a `pending`
   marker). */
function markdownToHtml(s) {
  if (!s) return '';

  // Phase 0: strip stream-internal think markers if they ever leak
  // through. They normally get consumed by chat_controller before
  // anything is persisted to the message, but a future provider
  // could ship them in the raw content; strip silently.
  let work = s
    .replace(/<!-- LUMEN_THINK_START -->/g, '')
    .replace(/<!-- LUMEN_THINK_END -->/g, '');

  // Phase 1: collapse raw tool-body blocks into pending markers so
  // the file body never reaches the markdown renderer. Mirrors
  // `streamingToolPreview` in `tool_segments.dart` — keep these in
  // sync if you add a new body-shaped tool there.
  work = collapseRawToolBlocks(work);

  // Phase 2: extract Lumen markers into NUL-delimited placeholders
  // BEFORE HTML escaping. The placeholders themselves are never
  // markdown / HTML metacharacters so they survive both the
  // escaper and the markdown passes intact.
  const toolMarkers = [];
  const thinkMarkers = [];
  const errMarkers = [];

  // The `\n?` (instead of `\n`) on either side handles the empty-
  // content edge case the desktop emits when thinking has just
  // started: `<!-- LUMEN_THINKING active -->\n<!-- /LUMEN_THINKING -->`
  // — a single newline separator with no content. The desktop's
  // parser misses this case (renders briefly as raw text); we
  // catch it here so the phone shows the "Thinking…" pulse from
  // the very first frame.
  work = work.replace(
    /<!-- LUMEN_THINKING(\s+active)? -->\n?([\s\S]*?)\n?<!-- \/LUMEN_THINKING -->/g,
    (_m, activeFlag, content) => {
      thinkMarkers.push({ active: !!activeFlag, content });
      return `\u0000THINK${thinkMarkers.length - 1}\u0000`;
    }
  );
  // Marker grammar mirrors `tool_segments.dart::parseChatSegments`.
  // The trailing `|<nonce>` field (8 hex chars) is the desktop's
  // per-message impersonation defense — see the library doc on
  // that file. The remote app does NOT validate the nonce here
  // (it doesn't have access to the message's expected nonce
  // anyway), it just tolerates the field so real desktop-emitted
  // markers render correctly. Without the optional alternation
  // the previous `[^\s]*` capture would greedily eat
  // `ok|abc12345`, then no status comparison would match and the
  // chip would render with the wrong style.
  work = work.replace(
    /<!-- LUMEN_TOOL:([^|]*)\|([^|]*)\|(ok|err|pending|malformed)(?:\|[a-f0-9]+)? -->/g,
    (_m, id, arg, status) => {
      toolMarkers.push({ id, arg, status });
      return `\u0000TOOL${toolMarkers.length - 1}\u0000`;
    }
  );
  work = work.replace(
    /<!--\s*LUMEN_ERR:([a-z_]+)\|([^|]*?)\s*-->/g,
    (_m, kind, detail) => {
      errMarkers.push({ kind, detail });
      return `\u0000ERR${errMarkers.length - 1}\u0000`;
    }
  );

  // Phase 3: escape HTML; we re-introduce safe markup below.
  let out = work
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  // Phase 4: fenced code blocks.
  out = out.replace(/```([a-zA-Z0-9_-]*)\n([\s\S]*?)```/g, (_m, _lang, code) =>
    `<pre><code>${code.replace(/\n$/, '')}</code></pre>`
  );

  // Phase 5: headers.
  out = out.replace(/^###### (.+)$/gm, '<h6>$1</h6>');
  out = out.replace(/^##### (.+)$/gm,  '<h5>$1</h5>');
  out = out.replace(/^#### (.+)$/gm,   '<h4>$1</h4>');
  out = out.replace(/^### (.+)$/gm,    '<h3>$1</h3>');
  out = out.replace(/^## (.+)$/gm,     '<h2>$1</h2>');
  out = out.replace(/^# (.+)$/gm,      '<h1>$1</h1>');

  // Phase 6: inline code.
  out = out.replace(/`([^`\n]+?)`/g, '<code>$1</code>');

  // Phase 7: bold + italic. Bold first so `***x***` becomes <b><i>x</i></b>.
  out = out.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/\*([^*\n]+)\*/g, '<em>$1</em>');

  // Phase 8: substitute marker placeholders with rendered HTML.
  out = out.replace(/\u0000THINK(\d+)\u0000/g, (_m, idx) =>
    renderThinkingBlock(thinkMarkers[+idx])
  );
  out = out.replace(/\u0000TOOL(\d+)\u0000/g, (_m, idx) =>
    renderToolPill(toolMarkers[+idx])
  );
  out = out.replace(/\u0000ERR(\d+)\u0000/g, (_m, idx) =>
    renderErrorChip(errMarkers[+idx])
  );

  return out;
}

/* Map of body-shaped tool names → { id (lowercase id used in
   markers), closer (the `<<<END_X>>>` token that terminates this
   tool's body) }. These are the only tools whose raw bodies dump
   the file contents into the live chat — short single-line tools
   like READ_FILE / TREE / SEARCH_TEXT carry no body so the
   "leaks code mid-stream" failure mode doesn't apply. Add a new
   entry here when you add a new body-shaped tool to
   `lib/services/tool_registry.dart`. */
const RAW_TOOL_BODIES = {
  CREATE_FILE: { id: 'create_file', closer: 'END_FILE' },
  EDIT_FILE:   { id: 'edit_file',   closer: 'END_EDIT' },
  MULTI_EDIT:  { id: 'multi_edit',  closer: 'END_EDIT' },
  EDIT_RANGE:  { id: 'edit_range',  closer: 'END_EDIT' },
  APPEND_FILE: { id: 'append_file', closer: 'END_APPEND' },
};

/* Replace raw `<<<TOOL: arg>>>…body…<<<END_X>>>` blocks with
   pending LUMEN_TOOL markers — same conversion the desktop applies
   in `streamingToolPreview`. Two passes:

     1. Fully-bracketed blocks (opener + body + closer present).
        Replace whole span. Covers both well-formed mid-stream tool
        calls AND structurally-malformed ones — the PWA doesn't
        validate inner shape (no SEARCH/REPLACE check), it just
        hides the body.
     2. Trailing incomplete opener (model started a file body but
        the closer hasn't arrived yet). Replace from the opener to
        the end of the buffer with a pending marker so the partial
        body stays hidden until the next delta brings the closer.

   Anything not matching either pass passes through untouched, so a
   conversational `<<<X>>>` that happens to use triple angle
   brackets is left alone. */
function collapseRawToolBlocks(content) {
  let out = content;

  // Pass 1: complete blocks.
  for (const [name, { id, closer }] of Object.entries(RAW_TOOL_BODIES)) {
    const re = new RegExp(
      `<<<${name}:\\s*([^>\\n]*?)\\s*>>>[\\s\\S]*?<<<${closer}>>>`,
      'g'
    );
    out = out.replace(re, (_m, arg) => toolMarker(id, arg, 'pending'));
  }

  // Pass 2: trailing incomplete opener. Find the LAST opener in
  // the buffer; if it has no matching closer between it and the
  // end of the string, replace from there. We only check the last
  // opener because the buffer can only have ONE incomplete tail
  // at a time during streaming.
  const lastOpenerRe = /<<<(CREATE_FILE|EDIT_FILE|MULTI_EDIT|APPEND_FILE):\s*([^>\n]*?)\s*>>>/g;
  let lastMatch = null;
  let m;
  while ((m = lastOpenerRe.exec(out)) !== null) lastMatch = m;
  if (lastMatch) {
    const name = lastMatch[1];
    const arg = lastMatch[2] || '';
    const meta = RAW_TOOL_BODIES[name];
    if (meta) {
      const tail = out.slice(lastMatch.index + lastMatch[0].length);
      if (!tail.includes(`<<<${meta.closer}>>>`)) {
        out = out.slice(0, lastMatch.index) +
              toolMarker(meta.id, arg, 'pending');
      }
    }
  }

  return out;
}

function toolMarker(id, arg, status) {
  return `\n<!-- LUMEN_TOOL:${id}|${encodeURIComponent(arg.trim())}|${status} -->\n`;
}

/* Render a Lumen tool marker as a small inline pill. Mirrors the
   desktop's tool-card affordance in spirit — tool name, optional
   arg (typically a file path), and an ok/err status icon. The
   pill sits on its own line because marker emission almost always
   ships with surrounding newlines from the agent loop. */
function renderToolPill({ id, arg, status }) {
  const ok = status === 'ok' || status === 'pending';
  const pending = status === 'pending';
  const malformed = status === 'malformed';
  const safeId = escapeHtml(id || 'tool');
  let argText = '';
  try { argText = decodeURIComponent(arg || ''); }
  catch (_) { argText = arg || ''; }
  const argHtml = argText
    ? ` <span class="tool-pill__arg">${escapeHtml(argText)}</span>`
    : '';
  let cls = 'tool-pill';
  let icon = '\u2713';
  if (malformed) {
    cls = 'tool-pill tool-pill--warn';
    icon = '!';
  } else if (!ok) {
    cls = 'tool-pill tool-pill--err';
    icon = '!';
  } else if (pending) {
    cls = 'tool-pill tool-pill--pending';
    icon = '\u2026';
  } else {
    cls = 'tool-pill tool-pill--ok';
  }
  return `<span class="${cls}"><span class="tool-pill__icon">${icon}</span>${safeId}${argHtml}</span>`;
}

/* Render a thinking trace as a collapsible <details> block. Open by
   default while still streaming so the user can watch reasoning
   appear; collapsed once complete (matches the desktop's behaviour
   in `_ThinkingBlock`). The content area renders as monospace,
   muted text — it's auxiliary, never the answer. We HTML-escape the
   inner content because thinking traces routinely contain `<` and
   `>` characters from XML-style tool plans. */
function renderThinkingBlock({ active, content }) {
  const safe = escapeHtml(content || '').replace(/\n/g, '<br>');
  const openAttr = active ? ' open' : '';
  const labelText = active ? 'Thinking…' : 'Thoughts';
  const stateCls = active
    ? 'lumen-thinking lumen-thinking--active'
    : 'lumen-thinking';
  return (
    `<details class="${stateCls}"${openAttr}>` +
      `<summary class="lumen-thinking__summary">` +
        `<span class="lumen-thinking__pulse"></span>` +
        `<span class="lumen-thinking__label">${labelText}</span>` +
      `</summary>` +
      `<div class="lumen-thinking__body">${safe}</div>` +
    `</details>`
  );
}

/* Render a provider-error marker as a compact error chip. The
   desktop renders these as a full Retry-capable card; on the PWA
   we just want the user to know the turn failed and what kind of
   failure it was — Retry happens from the desktop or by sending a
   new message. */
function renderErrorChip({ kind, detail }) {
  const safeKind = escapeHtml(kind || 'error');
  let detailText = '';
  try { detailText = decodeURIComponent(detail || ''); }
  catch (_) { detailText = detail || ''; }
  // Trim noisy provider preambles so the chip stays one-line-ish.
  detailText = detailText
    .replace(/^(?:Error[:\s]+)?(?:Anthropic|Gemini|GitHub Models|OpenAI|Ollama)\s*API error\s*\(\d+\)\s*:\s*/i, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (detailText.length > 220) detailText = detailText.slice(0, 217) + '…';
  const detailHtml = detailText
    ? ` <span class="error-chip__detail">${escapeHtml(detailText)}</span>`
    : '';
  return (
    `<span class="error-chip">` +
      `<span class="error-chip__icon">!</span>` +
      `<span class="error-chip__kind">${safeKind}</span>` +
      detailHtml +
    `</span>`
  );
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/* ── Pair screen ───────────────────────────────────────────── */

function renderPair() {
  const root = $('#app');
  root.className = 'screen-pair';
  root.innerHTML = '';
  root.appendChild(_pairScreen());
}

function _pairScreen() {
  const codeInput = el('input', {
    class: 'input input--code',
    type: 'tel',
    inputmode: 'numeric',
    pattern: '[0-9]*',
    maxlength: '6',
    autocomplete: 'one-time-code',
    placeholder: '••••••',
  });
  const nameInput = el('input', {
    class: 'input',
    type: 'text',
    placeholder: 'Phone, tablet, etc.',
    value: navigator.userAgentData?.platform || '',
  });
  const errBanner = el('div', { class: 'error-banner', style: 'display:none' });

  const submit = async () => {
    const code = codeInput.value.trim();
    if (code.length !== 6) {
      errBanner.textContent = 'Enter the 6-digit code shown on your desktop.';
      errBanner.style.display = '';
      return;
    }
    btn.disabled = true;
    btn.textContent = 'Pairing…';
    errBanner.style.display = 'none';
    try {
      const body = await apiJSON('/v1/pair/initiate', {
        method: 'POST',
        body: JSON.stringify({
          code,
          deviceName: nameInput.value.trim() || 'Lumen Remote',
        }),
      });
      state.token = body.token;
      state.device = body.device;
      localStorage.setItem(TOKEN_KEY, state.token);
      localStorage.setItem(DEVICE_KEY, JSON.stringify(state.device));
      openWS();
      location.hash = '#/projects';
      route();
    } catch (e) {
      const msg = e.body?.message || e.body?.error || 'Pairing failed.';
      errBanner.textContent = msg;
      errBanner.style.display = '';
    } finally {
      btn.disabled = false;
      btn.textContent = 'Pair';
    }
  };

  // Auto-submit when 6 digits are typed — feels native and avoids
  // the hunt for the Pair button on a small screen.
  codeInput.addEventListener('input', () => {
    codeInput.value = codeInput.value.replace(/\D/g, '');
    if (codeInput.value.length === 6) submit();
  });

  const btn = el('button', { class: 'button', onClick: submit }, 'Pair');

  return el('div', { class: 'pair' }, [
    el('div', { class: 'pair__logo' }, [
      el('div', { class: 'pair__logo-mark' }, 'L'),
      el('h1', { class: 'pair__title' }, 'Connect to Lumen'),
      el('p', { class: 'pair__hint' },
        'On your desktop, open Settings → Remote Access → Show pairing code, ' +
        'then enter the 6-digit code below.'
      ),
    ]),
    el('div', { class: 'pair__field' }, [
      el('div', { class: 'pair__label' }, 'Pairing code'),
      codeInput,
    ]),
    el('div', { class: 'pair__field' }, [
      el('div', { class: 'pair__label' }, 'Device name'),
      nameInput,
    ]),
    btn,
    errBanner,
  ]);
}

/* ── Projects screen ───────────────────────────────────────── */

async function renderProjects() {
  const root = $('#app');
  root.className = 'screen-projects';
  root.innerHTML = '';
  root.appendChild(_buildHeader({
    title: 'Lumen',
    actionLabel: 'Sign out',
    onAction: signOut,
  }));
  const content = el('div', { class: 'content' });
  root.appendChild(content);

  // Show whatever we have cached immediately for snappiness.
  if (state.projects) renderProjectsList(content, state.projects);
  else content.appendChild(el('div', { class: 'loading' }, [el('div', { class: 'spinner' })]));

  try {
    const body = await apiJSON('/v1/projects');
    state.projects = body.projects || [];
    renderProjectsList(content, state.projects);
  } catch (_) {
    content.innerHTML = '';
    content.appendChild(el('div', { class: 'empty-state' }, "Couldn't load projects."));
  }
}

function renderProjectsList(container, projects) {
  container.innerHTML = '';
  if (!projects.length) {
    container.appendChild(el('div', { class: 'empty-state' }, 'No projects yet.'));
    return;
  }
  const list = el('div', { class: 'list' });
  for (const p of projects) {
    list.appendChild(el('button', {
      class: 'list__item',
      onClick: () => { location.hash = `#/projects/${encodeURIComponent(p.id)}`; },
    }, [
      el('div', { class: 'list__icon' }, [svgIcon('folder')]),
      el('div', { class: 'list__body' }, [
        el('div', { class: 'list__title' }, p.name || p.path || 'Untitled'),
        el('div', { class: 'list__subtitle' }, [
          p.isCurrent ? el('span', { class: 'list__badge' }, 'Active') : null,
          p.isCurrent ? ' ' : null,
          `${p.chatCount || 0} chat${p.chatCount === 1 ? '' : 's'}`,
        ]),
      ]),
      p.lastUsedAt
        ? el('span', { class: 'list__meta' }, relativeTime(p.lastUsedAt))
        : null,
    ]));
  }
  container.appendChild(list);
}

function signOut() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(DEVICE_KEY);
  state.token = null;
  state.device = null;
  closeWS();
  location.hash = '#/pair';
  renderPair();
}

/* ── Chats screen (per project) ────────────────────────────── */

async function renderChats(projectId) {
  const root = $('#app');
  root.className = 'screen-chats';
  root.innerHTML = '';

  const project = state.projects?.find((p) => p.id === projectId);
  const title = project?.name || 'Chats';

  root.appendChild(_buildHeader({
    title,
    onBack: () => history.back(),
    actionLabel: '+ New',
    onAction: async () => {
      try {
        const body = await apiJSON('/v1/chats', {
          method: 'POST',
          body: JSON.stringify({
            workspacePath: project?.path || undefined,
          }),
        });
        location.hash = `#/chats/${encodeURIComponent(body.id)}`;
      } catch (_) {
        toast("Couldn't create chat.");
      }
    },
  }));

  const content = el('div', { class: 'content' });
  root.appendChild(content);

  const cached = state.projectChats.get(projectId);
  if (cached) renderChatsList(content, cached, projectId);
  else content.appendChild(el('div', { class: 'loading' }, [el('div', { class: 'spinner' })]));

  try {
    const body = await apiJSON(`/v1/projects/${encodeURIComponent(projectId)}/chats`);
    const chats = body.chats || [];
    state.projectChats.set(projectId, chats);
    renderChatsList(content, chats, projectId);
  } catch (_) {
    content.innerHTML = '';
    content.appendChild(el('div', { class: 'empty-state' }, "Couldn't load chats."));
  }
}

function renderChatsList(container, chats, _projectId) {
  container.innerHTML = '';
  if (!chats.length) {
    container.appendChild(el('div', { class: 'empty-state' }, 'No chats in this project yet.'));
    return;
  }
  // Sort newest-first by updatedAt.
  const sorted = [...chats].sort((a, b) =>
    (b.updatedAt || '').localeCompare(a.updatedAt || '')
  );
  const list = el('div', { class: 'list' });
  for (const c of sorted) {
    list.appendChild(el('button', {
      class: 'list__item',
      onClick: () => { location.hash = `#/chats/${encodeURIComponent(c.id)}`; },
    }, [
      el('div', { class: 'list__icon' }, [svgIcon('chat')]),
      el('div', { class: 'list__body' }, [
        el('div', { class: 'list__title' }, c.title || 'Untitled'),
        el('div', { class: 'list__subtitle' }, c.model || ''),
      ]),
      c.updatedAt
        ? el('span', { class: 'list__meta' }, relativeTime(c.updatedAt))
        : null,
    ]));
  }
  container.appendChild(list);
}

/* ── Chat screen ───────────────────────────────────────────── */

async function renderChat(chatId) {
  const root = $('#app');
  root.className = 'screen-chat';
  root.innerHTML = '';

  const chat = el('div', { class: 'chat', dataset: { chatId } });
  state.ui.chatScreen = chat;

  const header = _buildHeader({
    title: 'Loading…',
    onBack: () => history.back(),
  });
  chat.appendChild(header);

  const messages = el('div', { class: 'chat__messages' });
  _bindAutoScroll(messages);
  chat.appendChild(messages);

  const composer = _buildComposer(chatId);
  chat.appendChild(composer);

  root.appendChild(chat);

  // Pre-select on the desktop so the chat we're viewing is the
  // active session there (matches PR 4 design — phone is driving
  // the desktop's active chat).
  apiJSON(`/v1/chats/${encodeURIComponent(chatId)}/select`, { method: 'POST' })
    .catch(() => { /* best-effort; surface via stream events */ });

  try {
    const session = await apiJSON(`/v1/chats/${encodeURIComponent(chatId)}`);
    state.chatById.set(chatId, session);
    header.querySelector('.header__title').textContent = session.title || 'Chat';
    renderChatMessages(messages, session);
    scrollToBottom(messages);
    updateChatThinkingState();
  } catch (_) {
    messages.appendChild(el('div', { class: 'empty-state' }, "Couldn't load chat."));
  }
}

function _buildHeader({ title, onBack, actionLabel, onAction }) {
  return el('div', { class: 'header' }, [
    onBack
      ? el('button', { class: 'header__back', onClick: onBack }, [svgIcon('back')])
      : el('div', { class: 'header__back', style: 'visibility:hidden' }),
    el('div', { class: 'header__title' }, title),
    el('div', { class: 'header__connection' }),
    _buildFullscreenToggle(),
    actionLabel
      ? el('button', { class: 'header__action', onClick: onAction }, actionLabel)
      : null,
  ]);
}

/* Fullscreen toggle. The Fullscreen API is widely supported on
   Android Chrome but only works on `<video>` elements in iOS
   Safari, so on iOS we hide the button rather than render one
   that no-ops. The icon flips to "collapse" while in fullscreen
   so the user always sees the OPPOSITE action they can take.
   This is a runtime escape hatch on top of the manifest's
   `display_override: ["fullscreen", ...]`.

   We register ONE document-level fullscreenchange listener at
   module load (see bottom of file) and re-query all toggle
   buttons by data attribute. Without that, every route change
   would leak an old button via a closure capture. */
function _buildFullscreenToggle() {
  const supported =
    typeof document.documentElement.requestFullscreen === 'function';
  if (!supported) {
    // Render a placeholder of the same width so other header
    // items don't shift between routes that do/don't have an
    // action button.
    return el('div', {
      class: 'header__back',
      style: 'visibility:hidden',
    });
  }
  const btn = el('button', {
    class: 'header__back',
    dataset: { role: 'fullscreen-toggle' },
    'aria-label': 'Toggle fullscreen',
  }, [svgIcon(document.fullscreenElement ? 'collapse' : 'expand')]);
  btn.addEventListener('click', () => {
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => { /* user-dismissed */ });
    } else {
      // requestFullscreen rejects if not in response to a user
      // gesture; we are, so this almost always succeeds. Silent
      // catch so a denied request doesn't surface a stack trace.
      document.documentElement.requestFullscreen().catch(() => {});
    }
  });
  return btn;
}

function _refreshFullscreenToggles() {
  const isFs = !!document.fullscreenElement;
  $$('[data-role="fullscreen-toggle"]').forEach((btn) => {
    btn.innerHTML = '';
    btn.appendChild(svgIcon(isFs ? 'collapse' : 'expand'));
  });
}
// One listener for the lifetime of the page; refreshes all
// currently-mounted toggles. Deliberately attached at module
// load rather than per-button to avoid closure leaks.
document.addEventListener('fullscreenchange', _refreshFullscreenToggles);

function _buildModelPill(chatId) {
  // The pill renders the chat's current model as a tappable chip.
  // Tapping opens `_openModelPicker` which fetches /v1/models on
  // demand — we don't preload because the list is small (typically
  // <10 entries) and a stale cache here would silently send to a
  // model the desktop has since disabled.
  const pill = el('button', {
    class: 'model-pill',
    type: 'button',
    'aria-label': 'Change model',
  }, [
    el('span', { class: 'model-pill__label' }, modelLabel(currentChatModel())),
    el('span', { class: 'model-pill__chevron' }, '\u2304'),
  ]);
  pill.addEventListener('click', () => _openModelPicker(chatId, pill));
  return pill;
}

function _buildComposer(chatId) {
  const input = el('textarea', {
    class: 'chat__input',
    rows: '1',
    placeholder: 'Message…',
    autocomplete: 'off',
    autocorrect: 'on',
    autocapitalize: 'sentences',
  });
  const send = el('button', {
    class: 'chat__send',
    type: 'button',
  }, [svgIcon('send')]);
  send.disabled = true;

  const cancel = el('button', {
    class: 'chat__cancel',
    type: 'button',
    style: 'display:none',
  }, [svgIcon('stop')]);

  // Auto-grow textarea up to ~6 rows. Resetting to auto first is
  // load-bearing — without it the height monotonically grows on
  // shrink because scrollHeight reads the previous max.
  const autoresize = () => {
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, 140)}px`;
    send.disabled = !input.value.trim();
  };
  input.addEventListener('input', autoresize);

  // Enter sends, Shift+Enter inserts newline (desktop). On a
  // touch keyboard "return" inserts newline by default; user taps
  // the send button. Both work.
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !('ontouchstart' in window)) {
      e.preventDefault();
      submit();
    }
  });

  const submit = async () => {
    const text = input.value.trim();
    if (!text) return;
    send.disabled = true;
    try {
      await apiJSON(`/v1/chats/${encodeURIComponent(chatId)}/messages`, {
        method: 'POST',
        body: JSON.stringify({ text }),
      });
      input.value = '';
      autoresize();
    } catch (_) {
      toast("Couldn't send.");
    } finally {
      autoresize();
    }
  };
  send.addEventListener('click', submit);

  cancel.addEventListener('click', async () => {
    try {
      await apiJSON(`/v1/chats/${encodeURIComponent(chatId)}/cancel`, {
        method: 'POST',
      });
    } catch (_) { toast("Couldn't cancel."); }
  });

  // The composer wrapper holds the model pill on top, then both
  // buttons + input; only one of (send, cancel) is visible at a
  // time, driven by isGenerating.
  const inputRow = el('div', { class: 'chat__composer-row' }, [
    input,
    send,
    cancel,
  ]);
  const wrapper = el('div', { class: 'chat__composer' }, [
    _buildModelPill(chatId),
    inputRow,
  ]);
  wrapper.dataset.role = 'composer';
  return wrapper;
}

/* Look up the model string for the current chat. Falls back to
   the controller's globally-selected model if the chat-screen
   cache hasn't loaded the session yet (race during initial
   render). */
function currentChatModel() {
  const chat = state.ui.chatScreen;
  if (!chat) return null;
  const id = chat.dataset.chatId;
  return state.chatById.get(id)?.model || null;
}

/* Drop the provider prefix for display ("claude:claude-opus-4-7"
   → "claude-opus-4-7"). Keeps the pill from being dominated by
   the namespace; the user picks from a list that shows the same
   shortened name, so there's no ambiguity. */
function modelLabel(modelId) {
  if (!modelId) return 'Model';
  const colon = modelId.indexOf(':');
  return colon >= 0 ? modelId.substring(colon + 1) : modelId;
}

let _modelSheetOpen = false;

async function _openModelPicker(chatId, pillNode) {
  if (_modelSheetOpen) return;
  _modelSheetOpen = true;
  // Fetch fresh — the desktop user might enable/disable models
  // between PWA sessions and we don't want stale picker entries.
  let body;
  try {
    body = await apiJSON('/v1/models');
  } catch (_) {
    _modelSheetOpen = false;
    toast("Couldn't load models.");
    return;
  }
  const models = (body.enabled?.length ? body.enabled : body.available) || [];
  const selected = body.selected;

  const overlay = el('div', { class: 'sheet-overlay' });
  const sheet = el('div', { class: 'sheet' }, [
    el('div', { class: 'sheet__handle' }),
    el('div', { class: 'sheet__title' }, 'Select model'),
  ]);
  const list = el('div', { class: 'sheet__list' });
  for (const m of models) {
    const isCurrent = m === selected;
    const row = el('button', {
      class: 'sheet__item' + (isCurrent ? ' is-active' : ''),
      type: 'button',
    }, [
      el('div', { class: 'sheet__item-body' }, [
        el('div', { class: 'sheet__item-name' }, modelLabel(m)),
        el('div', { class: 'sheet__item-provider' }, providerOf(m)),
      ]),
      isCurrent
        ? el('div', { class: 'sheet__item-check' }, '\u2713')
        : null,
    ]);
    row.addEventListener('click', async () => {
      try {
        await apiJSON(`/v1/chats/${encodeURIComponent(chatId)}/model`, {
          method: 'POST',
          body: JSON.stringify({ model: m }),
        });
        // Optimistic update — the WS `chat_updated` event will
        // also arrive and bring the cache in line, but updating
        // the pill immediately feels snappier on a phone tap.
        const session = state.chatById.get(chatId);
        if (session) session.model = m;
        if (pillNode) {
          const labelNode = pillNode.querySelector('.model-pill__label');
          if (labelNode) labelNode.textContent = modelLabel(m);
        }
      } catch (e) {
        toast(e?.body?.error === 'unknown_model'
          ? 'Model not available.'
          : "Couldn't switch model.");
      } finally {
        closeSheet();
      }
    });
    list.appendChild(row);
  }
  if (!models.length) {
    list.appendChild(el('div', { class: 'empty-state' },
      'No models enabled. Enable some in the desktop Settings → Model Management.'));
  }
  sheet.appendChild(list);

  function closeSheet() {
    _modelSheetOpen = false;
    overlay.classList.remove('is-shown');
    sheet.classList.remove('is-shown');
    setTimeout(() => {
      overlay.remove();
      sheet.remove();
    }, 200);
  }
  overlay.addEventListener('click', closeSheet);
  document.body.appendChild(overlay);
  document.body.appendChild(sheet);
  // Force a layout pass before the .is-shown class so the
  // CSS transition runs. Without this the sheet jumps in.
  requestAnimationFrame(() => {
    overlay.classList.add('is-shown');
    sheet.classList.add('is-shown');
  });
}

/* Pull the provider out of a prefixed model id ("claude:opus-4-7"
   → "claude"). Used only for display; routing uses the full id. */
function providerOf(modelId) {
  if (!modelId) return '';
  const i = modelId.indexOf(':');
  return i >= 0 ? modelId.substring(0, i) : '';
}

function updateChatThinkingState() {
  const chat = state.ui.chatScreen;
  if (!chat) return;
  const send = chat.querySelector('.chat__send');
  const cancel = chat.querySelector('.chat__cancel');
  if (state.isGenerating) {
    send.style.display = 'none';
    cancel.style.display = '';
  } else {
    send.style.display = '';
    cancel.style.display = 'none';
  }
  // Add or remove the "thinking…" indicator at the bottom of
  // the message list. Matches the desktop's "thinking" pill.
  const messages = chat.querySelector('.chat__messages');
  let thinking = chat.querySelector('.thinking');
  if (state.isGenerating && !thinking) {
    // Only show if the last message isn't already a streaming
    // assistant bubble (avoids two indicators).
    const last = messages.lastElementChild;
    const lastIsStreaming = last?.classList?.contains('bubble--assistant') &&
      last.querySelector('.bubble__cursor');
    if (!lastIsStreaming) {
      thinking = el('div', { class: 'thinking' }, [
        el('span', { class: 'thinking__dot' }),
        el('span', { class: 'thinking__dot' }),
        el('span', { class: 'thinking__dot' }),
      ]);
      messages.appendChild(thinking);
      _scrollIfPinned(messages);
    }
  } else if (!state.isGenerating && thinking) {
    thinking.remove();
  }
}

function renderChatMessages(messages, session) {
  messages.innerHTML = '';
  for (const m of session.messages || []) {
    messages.appendChild(_buildBubble(m));
  }
}

function _buildBubble(msg) {
  const role = msg.role || 'assistant';
  const cls = `bubble bubble--${role}`;
  const node = el('div', { class: cls, dataset: { messageId: msg.id } });
  // System / tool / unknown roles get the centered subtle style.
  if (role !== 'user' && role !== 'assistant') {
    node.appendChild(document.createTextNode(msg.displayContent || msg.content || ''));
    return node;
  }
  if (role === 'assistant') {
    const content = el('div', { class: 'bubble__content' });
    content.innerHTML = markdownToHtml(msg.content || '');
    node.appendChild(content);
  } else {
    // User bubbles render as plain text — markdown in user input is
    // rare and rendering it could be confusing (e.g. accidental ##).
    const content = el('div', { class: 'bubble__content' });
    content.textContent = msg.displayContent || msg.content || '';
    node.appendChild(content);
  }
  return node;
}

/* Distance-from-bottom threshold (px) used to:
   - re-engage auto-follow when the user scrolls back near the bottom
   - decide whether a freshly-rendered bubble should pin to bottom
   100px is generous enough to handle imprecise touch scrolling on
   phones (a finger flick rarely lands exactly at scrollHeight). */
const PIN_SLACK_PX = 100;

/* "Pinned-to-bottom" state lives as a dataset flag on the messages
   container. Tying it to the DOM node (rather than module state)
   means each chat screen render starts in the pinned-true state
   without us having to remember to reset a global on every route
   change.

   The flag is the source of truth for "should this delta scroll the
   view?". We deliberately DON'T re-derive it from the layout after a
   content mutation — that's the bug we're fixing here: appending
   content grows `scrollHeight` without changing `scrollTop`, so a
   live `isNearBottom` reading taken after the mutation always reads
   "no, the user has scrolled up" even when they haven't moved a
   pixel. The flag, by contrast, only flips on actual user scroll
   events (and on programmatic scroll-to-bottom, which is a no-op
   re-affirmation). */
function _isPinned(messages) {
  // Default to true — a fresh container with no flag set should
  // auto-follow the stream. Only an explicit 'false' unpins.
  return messages.dataset.pinned !== 'false';
}
function _setPinned(messages, pinned) {
  messages.dataset.pinned = pinned ? 'true' : 'false';
}

/* Bind the scroll listener that maintains the pinned flag. Called
   from `renderChat` every time the chat screen mounts. The listener
   checks distance-from-bottom on every scroll frame:
     - within slack of the bottom → pinned = true (auto-follow on)
     - past slack from the bottom → pinned = false (user is reading)
   Using `passive: true` avoids blocking scroll on slow devices
   (the listener never calls preventDefault). */
function _bindAutoScroll(messages) {
  messages.addEventListener('scroll', () => {
    const distance =
      messages.scrollHeight - messages.scrollTop - messages.clientHeight;
    _setPinned(messages, distance < PIN_SLACK_PX);
  }, { passive: true });
}

/* Pin to the bottom. Force the flag true (so an in-progress user
   scroll-up doesn't fight the next delta) and scroll. Two RAF hops
   handles the "first frame: layout; second frame: scrollHeight is
   correct" case for media-heavy bubbles (font / image loads after
   the first frame). For pure text streams the second hop is a
   harmless no-op. */
function scrollToBottom(messages) {
  _setPinned(messages, true);
  requestAnimationFrame(() => {
    messages.scrollTop = messages.scrollHeight;
    requestAnimationFrame(() => {
      messages.scrollTop = messages.scrollHeight;
    });
  });
}

/* Conditional version: scroll only if the user is currently pinned.
   Used by streaming-delta callbacks so a user reading scroll-back
   isn't yanked away from their position. */
function _scrollIfPinned(messages) {
  if (_isPinned(messages)) scrollToBottom(messages);
}

/* ── Streaming hooks (called from event dispatch) ──────────── */

function onMessageAdded(chatId, message) {
  // Update cache regardless of which screen is rendered.
  const session = state.chatById.get(chatId);
  if (session) session.messages.push(message);

  if (state.ui.chatScreen?.dataset?.chatId !== chatId) return;
  const messages = state.ui.chatScreen.querySelector('.chat__messages');
  const thinking = state.ui.chatScreen.querySelector('.thinking');
  if (thinking) thinking.remove();
  // Don't double-append if a bubble with this id already exists
  // (could happen on a reconnect that replays missed events).
  if (messages.querySelector(`[data-message-id="${CSS.escape(message.id)}"]`)) return;
  // For user messages, always pin — the user just hit Send, they
  // want to see their own bubble. For assistant adds, follow the
  // existing pinned state.
  const force = message.role === 'user';
  messages.appendChild(_buildBubble(message));
  if (force) scrollToBottom(messages);
  else _scrollIfPinned(messages);
}

function onMessageDelta(chatId, messageId, content) {
  const session = state.chatById.get(chatId);
  if (session) {
    const m = session.messages.find((x) => x.id === messageId);
    if (m) m.content = content;
  }

  if (state.ui.chatScreen?.dataset?.chatId !== chatId) return;
  const messages = state.ui.chatScreen.querySelector('.chat__messages');
  let bubble = messages.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
  if (!bubble) {
    // Server emitted a delta before the matching `message_added` —
    // synthesise an empty bubble. Robust against reconnect ordering.
    bubble = _buildBubble({ id: messageId, role: 'assistant', content: '' });
    messages.appendChild(bubble);
  }
  const inner = bubble.querySelector('.bubble__content');
  // Streaming cursor adds a tasteful "still typing" affordance.
  inner.innerHTML = `${markdownToHtml(content || '')}<span class="bubble__cursor"></span>`;
  // Use the cached pinned flag rather than recomputing isNearBottom
  // here — the innerHTML mutation above just grew scrollHeight
  // without moving scrollTop, so a live distance-from-bottom check
  // would now read "user has scrolled up" even when they haven't.
  // The flag is only flipped by genuine user scroll events.
  _scrollIfPinned(messages);
}

function onMessageComplete(chatId, messageId) {
  if (state.ui.chatScreen?.dataset?.chatId !== chatId) return;
  const messages = state.ui.chatScreen.querySelector('.chat__messages');
  const bubble = messages.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
  if (!bubble) return;
  const cursor = bubble.querySelector('.bubble__cursor');
  if (cursor) cursor.remove();
  // The completion event triggers re-renders elsewhere (e.g. the
  // thinking block flips from active=true → active=false and
  // collapses, shrinking the bubble). If the user was following
  // along at the bottom, re-pin so the answer's last line stays in
  // view instead of getting pushed below the fold by the collapse.
  _scrollIfPinned(messages);
}

function onMessageDeleted(chatId, messageId) {
  const session = state.chatById.get(chatId);
  if (session) session.messages = session.messages.filter((m) => m.id !== messageId);
  if (state.ui.chatScreen?.dataset?.chatId !== chatId) return;
  const bubble = state.ui.chatScreen.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
  if (bubble) bubble.remove();
}
