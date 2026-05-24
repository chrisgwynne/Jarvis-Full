// Content script: notify the service worker when the selection changes so it can push
// fresh context to Jarvis without the host having to poll.

(() => {
  let lastSent = "";
  const notify = () => {
    const sel = window.getSelection ? window.getSelection().toString() : "";
    const trimmed = sel.slice(0, 8000);
    if (trimmed === lastSent) return;
    lastSent = trimmed;
    try { chrome.runtime.sendMessage({ type: "selection", length: trimmed.length }); } catch { /* extension reloading */ }
  };
  document.addEventListener("selectionchange", () => {
    // debounce — selectionchange fires per drag tick
    if (notify._t) clearTimeout(notify._t);
    notify._t = setTimeout(notify, 220);
  }, { passive: true });
})();
