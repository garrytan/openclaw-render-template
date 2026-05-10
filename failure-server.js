// Minimal HTTP server that serves a status page when alphaclaw has failed
// to start. Keeps the Render container Live (port 3000 bound, /health 200)
// so the Shell tab remains accessible for debugging.

const http = require("http");
const fs = require("fs");

const escape = (s) =>
  String(s).replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c]);

const safeRead = (p) => {
  try {
    return fs.readFileSync(p, "utf8");
  } catch (e) {
    return `(missing or unreadable: ${p} — ${e.message})`;
  }
};

const html = () => `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>AlphaClaw — startup failure</title>
  <style>
    body { font-family: ui-monospace, monospace; padding: 2em; max-width: 60em; line-height: 1.5; }
    h1 { color: #c00; }
    h2 { margin-top: 2em; }
    pre { background: #f5f5f5; padding: 1em; overflow: auto; max-height: 30em; border: 1px solid #ddd; }
    .ok { color: #060; }
    code { background: #f5f5f5; padding: 0.1em 0.4em; }
  </style>
</head>
<body>
  <h1>AlphaClaw failed to start</h1>
  <p><strong class="ok">The container is up</strong> — but the <code>alphaclaw start</code> process exited unexpectedly. This page is the failure-mode fallback so the deploy stays Live and you can debug from the Render Shell tab.</p>

  <h2>What to do</h2>
  <ol>
    <li>Open the Render Shell tab for this service.</li>
    <li>Inspect the boot log: <code>cat /data/start.log</code></li>
    <li>Try running alphaclaw manually to see live output: <code>/app/node_modules/.bin/alphaclaw start</code></li>
    <li>Check that <code>openclaw</code> resolves on PATH: <code>which openclaw &amp;&amp; openclaw --version</code></li>
  </ol>

  <h2>/data/start.log</h2>
  <pre>${escape(safeRead("/data/start.log"))}</pre>
</body>
</html>`;

const server = http.createServer((req, res) => {
  if (req.url === "/health" || req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(html());
});

const PORT = parseInt(process.env.PORT, 10) || 3000;
server.listen(PORT, "0.0.0.0", () => {
  console.log(`[failure-server] listening on port ${PORT}`);
});
