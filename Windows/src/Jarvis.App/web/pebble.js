// Pebble renderer.
// Receives state + perf + presence updates from the WPF host via window.chrome.webview.postMessage.

(() => {
  // Every state the WPF PebbleState enum can produce. Lowercased before being applied
  // as a CSS class. Add new states here when extending PebbleState.cs.
  const VALID_STATES = new Set([
    'Idle','Listening','Thinking','Speaking','Working','Alert','Focused','Muted','Error',
    'SpeakingRemote','Reconnecting','Degraded'
  ]);
  const VALID_ATTENTION = new Set(['idle','ambient','focused','active']);
  const VALID_AMP = new Set(['low','mid','high']);

  const pebble = document.getElementById('pebble');
  const hud = document.getElementById('hud');
  const hudCpu = document.getElementById('hud-cpu');
  const hudMem = document.getElementById('hud-mem');
  const hudFps = document.getElementById('hud-fps');

  function clearPrefixed(prefix) {
    for (const cls of [...pebble.classList]) {
      if (cls.startsWith(prefix)) pebble.classList.remove(cls);
    }
  }

  function applyState(state) {
    if (!VALID_STATES.has(state)) return;
    clearPrefixed('state-');
    pebble.classList.add('state-' + state.toLowerCase());
  }

  function applyAttention(mode, intensity) {
    if (!VALID_ATTENTION.has(mode)) return;
    clearPrefixed('attention-');
    pebble.classList.add('attention-' + mode);
    if (typeof intensity === 'number') {
      pebble.style.setProperty('--intensity', Math.max(0, Math.min(1, intensity)).toFixed(3));
    }
  }

  function applyAmplitude(bucket) {
    if (!VALID_AMP.has(bucket)) return;
    clearPrefixed('amp-');
    pebble.classList.add('amp-' + bucket);
  }

  // Wake & interruption are one-shots: add the class, schedule its removal so a fresh
  // event re-triggers the animation. Reflow trick avoids the "animation already played"
  // problem if the same class is added twice quickly.
  function fireWake() {
    pebble.classList.remove('is-wake');
    void pebble.offsetWidth;
    pebble.classList.add('is-wake');
    setTimeout(() => pebble.classList.remove('is-wake'), 820);
  }
  function fireInterruption() {
    pebble.classList.remove('is-interrupted');
    void pebble.offsetWidth;
    pebble.classList.add('is-interrupted');
    setTimeout(() => pebble.classList.remove('is-interrupted'), 340);
  }

  function applyHud(on) {
    if (!hud) return;
    if (on) hud.removeAttribute('hidden'); else hud.setAttribute('hidden', '');
  }

  function applyMetrics(m) {
    if (!hud || hud.hasAttribute('hidden')) return;
    if (m.cpu !== undefined && hudCpu) hudCpu.textContent = (+m.cpu).toFixed(1) + '%';
    if (m.mem !== undefined && hudMem) hudMem.textContent = (+m.mem).toFixed(0) + 'MB';
  }

  // Hover magnetism — the host window is click-through, but pointermove still reaches the
  // WebView. When the cursor crosses the pebble bounds we add a brief "noticed" beat.
  document.body.addEventListener('pointerenter', () => pebble.classList.add('is-hover'));
  document.body.addEventListener('pointerleave', () => pebble.classList.remove('is-hover'));

  // FPS — measure on the renderer side; WPF can't see WebView frame rate.
  let frames = 0;
  function frameTick() { frames++; requestAnimationFrame(frameTick); }
  requestAnimationFrame(frameTick);
  setInterval(() => {
    if (hudFps) hudFps.textContent = frames + '';
    frames = 0;
  }, 1000);

  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.addEventListener('message', (ev) => {
      try {
        const msg = ev.data;
        if (!msg || typeof msg !== 'object') return;
        switch (msg.type) {
          case 'state':        if (typeof msg.value === 'string')  applyState(msg.value); break;
          case 'hud':          if (typeof msg.value === 'boolean') applyHud(msg.value); break;
          case 'metrics':      if (msg.value) applyMetrics(msg.value); break;
          case 'wake':         fireWake(); break;
          case 'interruption': fireInterruption(); break;
          case 'amplitude':    if (typeof msg.value === 'string') applyAmplitude(msg.value); break;
          case 'attention':    if (msg.value) applyAttention(msg.value.mode, msg.value.intensity); break;
          case 'menu':
            if (msg.value === true)  pebble.classList.add('is-menu-open');
            if (msg.value === false) pebble.classList.remove('is-menu-open');
            break;
        }
      } catch { /* never crash the renderer */ }
    });
  } else {
    // Standalone preview cycle (no WPF host)
    let i = 0;
    const cycle = ['Idle','Listening','Thinking','Speaking','SpeakingRemote','Reconnecting','Degraded','Working','Focused','Alert','Muted','Error'];
    applyState(cycle[0]);
    applyAttention('ambient', 0.5);
    setInterval(() => { i = (i + 1) % cycle.length; applyState(cycle[i]); }, 2200);
    setInterval(fireWake, 7000);
    applyHud(true);
    setInterval(() => applyMetrics({ cpu: Math.random()*2, mem: 180 + Math.random()*4 }), 1000);
  }

  window.__pebble = { applyState, applyAttention, applyAmplitude, fireWake, fireInterruption, applyHud, applyMetrics };
})();
