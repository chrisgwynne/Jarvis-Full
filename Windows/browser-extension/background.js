// Jarvis Context Bridge — service worker.
// Owns the authenticated WebSocket to the local Jarvis runtime. Receives host commands
// and replies with one ack per command (type: "ack", commandId: ...).

const PORT = 49321;
const BROWSER = (() => {
  if (navigator.userAgent.includes("Edg/")) return "edge";
  if (navigator.userAgent.includes("Brave/")) return "brave";
  return "chrome";
})();
const VERSION = chrome.runtime.getManifest().version;

let socket = null;
let connected = false;
let backoffMs = 500;
let lastContextSent = null;
let queuedContext = null;
let token = null;

async function loadToken() {
  return new Promise((resolve) =>
    chrome.storage.local.get("token", ({ token: t }) => resolve(t || null)));
}

async function connect() {
  token = await loadToken();
  if (!token) {
    // Without a token the server will reject the upgrade. Defer until the user pastes one.
    scheduleReconnect();
    return;
  }
  const url = `ws://127.0.0.1:${PORT}/?token=${encodeURIComponent(token)}`;
  try { socket = new WebSocket(url); }
  catch { scheduleReconnect(); return; }

  socket.addEventListener("open", () => {
    connected = true;
    backoffMs = 500;
    sendMessage({ type: "hello", browser: BROWSER, version: VERSION });
    if (queuedContext) { sendMessage(queuedContext); queuedContext = null; }
  });
  socket.addEventListener("close", () => { connected = false; socket = null; scheduleReconnect(); });
  socket.addEventListener("error", () => { /* close handler reconnects */ });
  socket.addEventListener("message", onHostMessage);
}

function scheduleReconnect() {
  const delay = Math.min(backoffMs, 15_000);
  backoffMs = Math.min(backoffMs * 2, 15_000);
  setTimeout(connect, delay);
}

function sendMessage(payload) {
  if (!connected || !socket || socket.readyState !== WebSocket.OPEN) {
    if (payload.type === "context") queuedContext = payload;
    return;
  }
  try {
    const json = JSON.stringify(payload);
    if (payload.type === "context" && lastContextSent === json) return;
    socket.send(json);
    if (payload.type === "context") lastContextSent = json;
  } catch { /* socket closing; reconnect path handles it */ }
}

function sendAck(commandId, fields = {}) {
  sendMessage({ type: "ack", commandId, accepted: true, completed: true, ...fields });
}

async function activeTab() {
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tabs[0] || null;
}

async function onHostMessage(ev) {
  let cmd;
  try { cmd = JSON.parse(ev.data); } catch { return; }
  if (!cmd || !cmd.commandId) {
    // Old-style commands (no commandId) are still tolerated for forward compatibility.
    if (!cmd) return;
  }
  const id = cmd.commandId || "noid";
  try {
    switch (cmd.type) {
      case "navigate": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        await chrome.tabs.update(tab.id, { url: cmd.url });
        return sendAck(id, { resultingUrl: cmd.url });
      }
      case "reload": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        await chrome.tabs.reload(tab.id);
        return sendAck(id);
      }
      case "back":
      case "forward": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (dir) => { dir === "back" ? history.back() : history.forward(); },
          args: [cmd.type]
        });
        return sendAck(id);
      }
      case "scroll": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (dy) => window.scrollBy({ top: dy, behavior: "smooth" }),
          args: [cmd.dy || 0]
        });
        return sendAck(id);
      }
      case "focusInput": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        const r = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (sel) => {
            const el = document.querySelector(sel);
            if (!el) return { ok: false, matches: 0 };
            el.focus();
            return { ok: true, matches: document.querySelectorAll(sel).length };
          },
          args: [cmd.selector]
        });
        const out = r && r[0] && r[0].result;
        if (!out || !out.ok) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "selector not found", matches: out ? out.matches : 0 });
        return sendAck(id, { matches: out.matches });
      }
      case "dryRun": {
        // Resolve the selector without doing anything; used by the host's two-phase click guard.
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        const r = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (sel) => {
            const els = document.querySelectorAll(sel);
            if (els.length === 0) return { matches: 0, sample: null };
            const first = els[0];
            const sample = `${first.tagName.toLowerCase()}${first.id ? "#" + first.id : ""}${first.className ? "." + (first.className + "").split(" ").filter(Boolean).join(".") : ""} ${(first.innerText || "").slice(0, 40)}`;
            return { matches: els.length, sample };
          },
          args: [cmd.selector]
        });
        const out = r && r[0] && r[0].result;
        return sendMessage({ type: "ack", commandId: id, accepted: true, completed: true, matches: out ? out.matches : 0, sample: out ? out.sample : null });
      }
      case "click": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        const r = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (sel) => {
            const els = document.querySelectorAll(sel);
            if (els.length !== 1) return { ok: false, matches: els.length };
            els[0].click();
            return { ok: true, matches: 1 };
          },
          args: [cmd.selector]
        });
        const out = r && r[0] && r[0].result;
        if (!out || !out.ok) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: out && out.matches !== 1 ? `selector matched ${out.matches}` : "click failed", matches: out ? out.matches : 0 });
        return sendAck(id);
      }
      case "listTargets": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        // Pull window screen position from the chrome.windows API (host-side mapping uses this).
        let chromeWindow = null;
        try { chromeWindow = await chrome.windows.get(tab.windowId); } catch {}
        const r = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: () => {
            const SELS = "button, a[href], [role=button], [role=link], [role=menuitem], [role=tab], [role=checkbox], input:not([type=hidden]), textarea, select, summary, [onclick]";
            const out = [];
            const seen = new WeakSet();
            const vh = window.innerHeight, vw = window.innerWidth;
            for (const el of document.querySelectorAll(SELS)) {
              if (seen.has(el)) continue; seen.add(el);
              const r = el.getBoundingClientRect();
              if (r.width < 4 || r.height < 4) continue;
              if (r.right < 0 || r.bottom < 0 || r.left > vw || r.top > vh) continue;
              const style = window.getComputedStyle(el);
              const visible = style.visibility !== "hidden" && style.display !== "none" && +style.opacity > 0.05;
              if (!visible) continue;
              const enabled = !el.disabled && el.getAttribute("aria-disabled") !== "true";
              const label =
                el.getAttribute("aria-label")
                || el.getAttribute("title")
                || (el.innerText || el.value || el.placeholder || el.alt || "").trim().slice(0, 80);
              if (!label || label.length === 0) continue;
              const tag = el.tagName.toLowerCase();
              const explicitRole = el.getAttribute("role");
              const role = explicitRole || (tag === "a" ? "link"
                : tag === "button" ? "button"
                : tag === "input" ? "textbox"
                : tag === "textarea" ? "textbox"
                : tag === "select" ? "combobox"
                : tag === "summary" ? "button"
                : "control");
              // Build a stable-ish selector: id wins, else tag + nth-of-type.
              let selector;
              if (el.id) selector = `#${CSS.escape(el.id)}`;
              else {
                const parent = el.parentElement;
                const sib = parent ? Array.from(parent.children).filter(c => c.tagName === el.tagName) : [el];
                const idx = sib.indexOf(el) + 1;
                selector = `${tag}:nth-of-type(${idx})`;
              }
              out.push({
                label, role, selector,
                x: Math.round(r.left), y: Math.round(r.top),
                width: Math.round(r.width), height: Math.round(r.height),
                visible: true, enabled
              });
              if (out.length >= 200) break;  // safety cap
            }
            // Viewport metadata: screen position of the page content area, plus DPR.
            // window.screenX/Y is the OUTER window position; we need the inner content
            // origin, so add the chrome offsets the browser exposes via outer-inner deltas.
            const outerLeft = window.screenX || 0;
            const outerTop = window.screenY || 0;
            const chromeTop = (window.outerHeight - window.innerHeight) - (window.screenY ? 0 : 0);
            return {
              targets: out,
              viewport: {
                screenX: outerLeft + (window.outerWidth - window.innerWidth),
                screenY: outerTop + chromeTop,
                width: window.innerWidth,
                height: window.innerHeight,
                dpr: window.devicePixelRatio || 1,
                scrollX: window.scrollX | 0,
                scrollY: window.scrollY | 0
              }
            };
          }
        });
        const payload = (r && r[0] && r[0].result) || { targets: [] };
        return sendMessage({
          type: "ack", commandId: id, accepted: true, completed: true,
          targets: payload.targets || [],
          viewport: payload.viewport || null
        });
      }
      case "extractSelection": {
        const tab = await activeTab();
        if (!tab) return sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: "no active tab" });
        pushContext();
        return sendAck(id);
      }
      default:
        return sendMessage({ type: "ack", commandId: id, accepted: false, completed: false, error: `unknown command: ${cmd.type}` });
    }
  } catch (err) {
    sendMessage({ type: "ack", commandId: id, accepted: true, completed: false, error: err && err.message ? err.message : String(err) });
  }
}

async function fetchActiveContext() {
  try {
    const tab = await activeTab();
    if (!tab || !tab.url) return null;
    const url = tab.url;
    const title = tab.title || "";
    let domain = null;
    try { domain = new URL(url).hostname; } catch {}
    let dom = { selectedText: null, focusedElementRole: null, isTextInputFocused: false };
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => {
          const sel = window.getSelection ? window.getSelection().toString() : "";
          const active = document.activeElement;
          let role = null, isTextInput = false;
          if (active) {
            role = active.getAttribute("role") || active.tagName.toLowerCase();
            const tag = active.tagName.toLowerCase();
            const editable = active.isContentEditable;
            const inputType = (active.getAttribute("type") || "text").toLowerCase();
            isTextInput = editable || tag === "textarea"
              || (tag === "input" && ["text","search","email","url","tel","password","number"].includes(inputType));
          }
          return { selectedText: sel ? sel.slice(0, 8000) : null, focusedElementRole: role, isTextInputFocused: isTextInput };
        }
      });
      if (results && results[0] && results[0].result) dom = results[0].result;
    } catch { /* chrome:// can't be scripted; carry on with tab info */ }
    return {
      type: "context", browser: BROWSER, version: VERSION,
      url, domain, title,
      selectedText: dom.selectedText,
      focusedElementRole: dom.focusedElementRole,
      isTextInputFocused: dom.isTextInputFocused
    };
  } catch { return null; }
}

async function pushContext() {
  const ctx = await fetchActiveContext();
  if (ctx) sendMessage(ctx);
}

chrome.tabs.onActivated.addListener(pushContext);
chrome.tabs.onUpdated.addListener((_id, info) => { if (info.status === "complete" || info.title || info.url) pushContext(); });
chrome.windows.onFocusChanged.addListener(pushContext);
chrome.runtime.onMessage.addListener((msg) => {
  if (!msg) return;
  if (msg.type === "selection") pushContext();
  if (msg.type === "tokenChanged" && socket) { try { socket.close(); } catch {} }
});

connect();
pushContext();
setInterval(() => sendMessage({ type: "ping" }), 25_000);
