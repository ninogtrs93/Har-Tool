(() => {
  const state = { baseUrl: null, connected: false, sessionId: null, warnings: [] };
  chrome.devtools.panels.create('HAR Capture', '', 'panel.html');

  function qs(k){ const u=new URL(location.href); return u.searchParams.get(k); }
  state.baseUrl = qs('base') || 'http://127.0.0.1:17777';
  state.sessionId = qs('session') || 'unknown';

  const cors = { headers: { 'Content-Type': 'application/json' } };

  async function post(path, data){
    try { await fetch(state.baseUrl + path, { method:'POST', ...cors, body: JSON.stringify(data)}); } catch {}
  }

  async function exportHar(){
    chrome.devtools.network.getHAR(async (harLog) => {
      if (chrome.runtime.lastError) {
        await post('/status', { sessionId: state.sessionId, type:'harError', message: chrome.runtime.lastError.message });
        return;
      }
      const har = { log: harLog };
      const entries = (har.log && har.log.entries) || [];
      let pending = entries.length;
      if (!pending) {
        await post('/har', { sessionId: state.sessionId, har, warnings: ['Geen entries in HAR'] });
        return;
      }
      entries.forEach((entry) => {
        try {
          entry.getContent((content, encoding) => {
            try {
              if (content != null) {
                entry.response = entry.response || {};
                entry.response.content = entry.response.content || {};
                entry.response.content.text = content;
                if (encoding) entry.response.content.encoding = encoding;
              }
            } catch (e) { state.warnings.push('Content attach mislukt'); }
            pending -= 1;
            if (pending === 0) post('/har', { sessionId: state.sessionId, har, warnings: state.warnings });
          });
        } catch (e) {
          pending -= 1; state.warnings.push('getContent exception');
          if (pending === 0) post('/har', { sessionId: state.sessionId, har, warnings: state.warnings });
        }
      });
    });
  }

  chrome.devtools.network.onRequestFinished.addListener((req) => {
    const url = req?.request?.url || '';
    if (url) post('/status', { sessionId: state.sessionId, type:'seen', url });
  });

  setInterval(async () => {
    try {
      const res = await fetch(state.baseUrl + '/command?sessionId=' + encodeURIComponent(state.sessionId));
      const cmd = await res.json();
      state.connected = true;
      if (cmd.command === 'exportHar') {
        await post('/status', { sessionId: state.sessionId, type:'exportStart' });
        await exportHar();
      }
    } catch {
      state.connected = false;
    }
  }, 1000);
})();
