'use strict';

(() => {
  const $ = id => document.getElementById(id);
  const encoder = new TextEncoder();
  const storageKey = 'zshell.browser-access.credential';
  let strings = {};
  let token = '';
  let socket;
  let terminal;
  let fit;
  let retry;
  let pairingTimer;
  let ticket = '';
  let selected = '';
  let attached = '';
  let ready = false;
  let authenticated = false;
  let manuallyDisconnected = false;
  let epoch = 0;
  let pendingBytes = 0;
  let attempts = 0;
  let resizeTimer;
  let lastSize = '';
  let stream = '';
  const text = key => strings[key] || key;
  const setStatus = key => { $('status').textContent = text(key); };

  try { token = sessionStorage.getItem(storageKey) || ''; } catch { /* Storage may be disabled. */ }

  async function post(path, body) {
    const response = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body), credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer' });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || text('failed'));
    return result;
  }

  function send(value) {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    if (socket.bufferedAmount > 64 * 1024) { socket.close(); return; }
    socket.send(JSON.stringify(value));
  }

  function initializeTerminal() {
    if (terminal) return;
    terminal = new Terminal({ allowProposedApi: true, scrollback: 5000, fontSize: 13,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
      theme: { background: '#111318', foreground: '#e5e7eb' }, screenReaderMode: false });
    fit = new FitAddon.FitAddon();
    terminal.loadAddon(fit);
    terminal.loadAddon(new Unicode11Addon.Unicode11Addon());
    terminal.unicode.activeVersion = '11';
    terminal.open($('terminal'));
    // A terminal's control replies must come from one renderer. The Mac keeps
    // answering queries; browser-generated replies are filtered to avoid echoes.
    const isReply = data => /^\x1b(?:\[(?:\?|>|=)?[0-9;:]*[cnR]|\][0-9]+;|P[01]\$r)/.test(data);
    terminal.onData(data => {
      if (!ready || isReply(data) || !socket || socket.readyState !== WebSocket.OPEN) return;
      const bytes = encoder.encode(data);
      if (bytes.length > 16 * 1024 || socket.bufferedAmount > 64 * 1024) { socket.close(); return; }
      socket.send(bytes);
    });
    terminal.onBinary(data => {
      if (!ready || !socket || socket.readyState !== WebSocket.OPEN) return;
      if (data.length > 16 * 1024 || socket.bufferedAmount > 64 * 1024) { socket.close(); return; }
      socket.send(Uint8Array.from(data, char => char.charCodeAt(0) & 255));
    });
    new ResizeObserver(() => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(resize, 120);
    }).observe($('terminal-scroll'));
  }

  function resize() {
    if (!ready || !$('control').checked || !terminal) return;
    const size = fit.proposeDimensions();
    if (!size) return;
    const columns = Math.max(1, Math.min(512, size.cols));
    const rows = Math.max(1, Math.min(256, size.rows, Math.floor(65536 / columns)));
    const key = `${columns}:${rows}`;
    if (key === lastSize) return;
    lastSize = key;
    send({ type: 'resize', columns, rows });
  }

  function select() {
    selected = $('sessions').value;
    if (!authenticated || !selected) return;
    attached = '';
    ready = false;
    lastSize = '';
    send({ type: 'select', session: selected });
  }

  function connect() {
    if (!token || manuallyDisconnected) return;
    clearTimeout(retry);
    if (socket) { socket.onclose = null; socket.close(); }
    const current = ++epoch;
    ready = false;
    authenticated = false;
    attached = '';
    pendingBytes = 0;
    setStatus('connecting');
    socket = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/terminal`);
    socket.binaryType = 'arraybuffer';
    socket.onopen = () => send({ type: 'authenticate', token });
    socket.onmessage = event => {
      if (current !== epoch) return;
      if (typeof event.data !== 'string') {
        const bytes = new Uint8Array(event.data);
        const currentStream = stream;
        pendingBytes += bytes.length;
        if (!terminal || pendingBytes > 512 * 1024) { socket.close(); return; }
        terminal.write(bytes, () => {
          if (current !== epoch) return;
          pendingBytes -= bytes.length;
          send({ type: 'ack', stream: currentStream, bytes: bytes.length });
        });
        return;
      }
      let message;
      try { message = JSON.parse(event.data); } catch { socket.close(); return; }
      switch (message.type) {
        case 'authenticated':
          authenticated = true;
          attempts = 0;
          $('pairing').hidden = true;
          $('workspace').hidden = false;
          $('connect').hidden = true;
          $('disconnect').hidden = false;
          $('forget').hidden = false;
          initializeTerminal();
          setStatus('connected');
          break;
        case 'sessions': {
          const previous = selected;
          const sessions = Array.isArray(message.sessions) ? message.sessions.slice(0, 128) : [];
          $('sessions').replaceChildren();
          for (const session of sessions) {
            const option = document.createElement('option');
            option.value = session.id;
            option.textContent = `${session.project} — ${session.title}`;
            $('sessions').append(option);
          }
          if (sessions.some(session => session.id === previous)) $('sessions').value = previous;
          selected = $('sessions').value;
          $('empty').hidden = sessions.length !== 0;
          if (selected && selected !== attached) select();
          break;
        }
        case 'reset':
          if (!terminal || message.session !== selected) return;
          stream = message.stream;
          terminal.write('', () => {
            if (current !== epoch || message.session !== selected || message.stream !== stream) return;
            terminal.reset();
            terminal.resize(message.columns, message.rows);
          });
          ready = false;
          lastSize = '';
          break;
        case 'size':
          if (terminal && message.session === selected) terminal.resize(message.columns, message.rows);
          break;
        case 'ready':
          if (message.session !== selected) return;
          attached = selected;
          const readyStream = stream;
          terminal.write('', () => {
            if (current !== epoch || message.session !== selected || readyStream !== stream) return;
            ready = true;
            terminal.focus();
            resize();
          });
          break;
        case 'unavailable':
          ready = false;
          attached = '';
          setStatus('empty');
          break;
        default: socket.close();
      }
    };
    socket.onclose = () => {
      if (current !== epoch) return;
      ready = false;
      authenticated = false;
      setStatus('disconnected');
      $('connect').hidden = false;
      $('disconnect').hidden = true;
      if (!manuallyDisconnected && attempts++ < 5) retry = setTimeout(connect, Math.min(10000, 500 * 2 ** attempts));
    };
    socket.onerror = () => setStatus('failed');
  }

  function disconnect() {
    manuallyDisconnected = true;
    clearTimeout(retry);
    clearTimeout(pairingTimer);
    if (socket) socket.close();
    ready = false;
  }

  function forget() {
    disconnect();
    token = '';
    ticket = '';
    try { sessionStorage.removeItem(storageKey); } catch { /* In-memory credentials are also cleared. */ }
    $('pairing').hidden = false;
    $('workspace').hidden = true;
    $('code').hidden = true;
    $('pair-instructions').hidden = true;
    $('pair').disabled = false;
    $('forget').hidden = true;
    $('connect').hidden = true;
  }

  async function pollPairing() {
    if (!ticket) return;
    try {
      const result = await post('/api/pair/status', { ticket });
      if (result.state === 'approved' && /^[a-f0-9]{64}$/.test(result.token)) {
        token = result.token;
        ticket = '';
        try { sessionStorage.setItem(storageKey, token); } catch { /* This browser can still connect for this page's lifetime. */ }
        manuallyDisconnected = false;
        connect();
      } else if (result.state === 'pending') pairingTimer = setTimeout(pollPairing, 1000);
      else {
        ticket = '';
        $('pair').disabled = false;
        setStatus('denied');
      }
    } catch {
      ticket = '';
      $('pair').disabled = false;
      setStatus('failed');
    }
  }

  $('pair-form').addEventListener('submit', async event => {
    event.preventDefault();
    $('pair').disabled = true;
    try {
      const result = await post('/api/pair', { name: $('client-name').value.trim() });
      ticket = result.ticket;
      $('code').textContent = result.code;
      $('code').hidden = false;
      $('pair-instructions').hidden = false;
      setStatus('waiting');
      pollPairing();
    } catch (error) { $('pair').disabled = false; $('status').textContent = error.message; }
  });
  $('sessions').addEventListener('change', select);
  $('control').addEventListener('change', () => { lastSize = ''; resize(); });
  $('connect').addEventListener('click', () => { manuallyDisconnected = false; attempts = 0; connect(); });
  $('disconnect').addEventListener('click', disconnect);
  $('forget').addEventListener('click', forget);
  window.addEventListener('pagehide', disconnect);

  fetch('/api/info', { cache: 'no-store', credentials: 'omit' }).then(response => response.json()).then(info => {
    strings = info.strings;
    document.documentElement.lang = info.language || 'en';
    document.documentElement.dir = info.language === 'ar' ? 'rtl' : 'ltr';
    const mappings = { title: 'title', pair: 'pair', 'name-label': 'name', 'pair-instructions': 'pairing',
      trust: 'trust', certificate: 'certificate', 'session-label': 'session', 'control-label': 'control',
      empty: 'empty', connect: 'connect', disconnect: 'disconnect', forget: 'forget' };
    for (const [id, key] of Object.entries(mappings)) $(id).textContent = text(key);
    document.title = `Zshell — ${text('title')}`;
    if (info.fingerprint) {
      $('trust').hidden = false;
      $('fingerprint').hidden = false;
      $('fingerprint').textContent = `${text('fingerprint')}: ${info.fingerprint}`;
      $('certificate').hidden = false;
    }
    if (info.local && info.remoteURL) {
      const url = new URL(info.remoteURL);
      if (url.protocol === 'https:') {
        $('remote').href = url.href;
        $('remote').textContent = `${text('remote')}: ${url.host}`;
        $('remote').hidden = false;
      }
    }
    setStatus('disconnected');
    if (token) { $('forget').hidden = false; connect(); }
  }).catch(() => setStatus('failed'));
})();
