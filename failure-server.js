// Minimal HTTP server that serves a status page when alphaclaw has failed
// to start. Keeps the Render container Live (port 3000 bound, /health 200)
// so the Shell tab remains accessible for debugging.
//
// IMPORTANT: this server is publicly reachable on the service URL. It must
// NOT expose any logs, env vars, file contents, or other potentially
// sensitive state. Direct the operator to the Render Shell tab to inspect
// /data/start.log there.

const http = require("http");

const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>AlphaClaw — startup failure</title>
  <style>
    body { font-family: ui-monospace, monospace; padding: 2em; max-width: 50em; line-height: 1.6; color: #222; }
    h1 { color: #c00; }
    code { background: #f5f5f5; padding: 0.1em 0.4em; border-radius: 3px; }
    .ok { color: #060; }
    ol li { margin-bottom: 0.5em; }
  </style>
</head>
<body>
  <h1>AlphaClaw failed to start</h1>
  <p><strong class="ok">The container is up</strong> — but the <code>alphaclaw start</code> process exited unexpectedly. This page is the failure-mode fallback so the deploy stays Live and you can debug from the Render Shell tab.</p>

  <h2>Debug steps</h2>
  <ol>
    <li>Open the Render Shell tab for this service (now reachable, since the container is healthy).</li>
    <li>Inspect the boot log: <code>cat /data/start.log</code></li>
    <li>Try running alphaclaw manually to see live output: <code>/app/node_modules/.bin/alphaclaw start</code></li>
    <li>Check that <code>openclaw</code> resolves on PATH: <code>which openclaw &amp;&amp; openclaw --version</code></li>
  </ol>

  <p style="margin-top: 3em; color: #888; font-size: 0.9em;">No log content is rendered on this page because the boot log can contain environment values. Use the Shell tab to inspect.</p>
</body>
</html>`;

const server = http.createServer((req, res) => {
  if (req.url === "/health" || req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(html);
});

const PORT = parseInt(process.env.PORT, 10) || 3000;
server.listen(PORT, "0.0.0.0", () => {
  console.log(`[failure-server] listening on port ${PORT}`);
});
