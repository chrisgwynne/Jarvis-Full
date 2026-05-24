const tokenInput = document.getElementById("token");
const statusEl = document.getElementById("status");

chrome.storage.local.get("token", ({ token }) => {
  if (token) tokenInput.value = token;
});

document.getElementById("save").addEventListener("click", () => {
  const token = tokenInput.value.trim();
  if (!token) { statusEl.textContent = "Please paste a token first."; return; }
  chrome.storage.local.set({ token }, () => {
    statusEl.textContent = "Saved. Reconnecting…";
    // Wake the service worker to pick up the new token.
    try { chrome.runtime.sendMessage({ type: "tokenChanged" }); } catch {}
  });
});
