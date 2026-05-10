# Agent notes for openclaw-render-template

This is a Docker-based one-click Render deploy of [`@chrysb/alphaclaw`](https://www.npmjs.com/package/@chrysb/alphaclaw), which wraps OpenClaw to run as a 24/7 service. Notes here are for AI agents (or future humans) who need to understand non-obvious behavior fast.

## Layout

- `Dockerfile` — image build. `CMD` is `alphaclaw start`; `tini` is PID 1.
- `render.yaml` — Render Blueprint config. Service is web, plan starter, port 3000, health check `/health`, `/data` 10 GB persistent disk.
- `package.json` — pins `@chrysb/alphaclaw`. `openclaw` arrives as a transitive dep.
- `debug-start.sh` — diagnostic boot script (see "Debug path" below).

## Critical PATH detail (don't remove)

`alphaclaw start` spawns `openclaw` by **bare name** in two places inside `node_modules/@chrysb/alphaclaw/lib/server/gateway.js`:

- A preflight `execSync("openclaw plugins list --json", ...)`
- The gateway run: `spawn("openclaw", ["gateway", "run"], ...)`

Both inherit `process.env.PATH` from the alphaclaw process. The default `node:22-slim` PATH is `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` — `/app/node_modules/.bin` is **not** on it, and that's where `openclaw` lives. If PATH isn't fixed, alphaclaw crashes with `Error: spawn openclaw ENOENT` and the container restart-loops.

The Dockerfile addresses this two ways (both intentional, keep both):

1. `ENV PATH="/app/node_modules/.bin:$PATH"` — primary fix
2. `RUN ln -sf /app/node_modules/.bin/{openclaw,alphaclaw} /usr/local/bin/...` — belt-and-suspenders so even a future refactor that drops the ENV line still works

## Render-specific gotchas

- **`dockerCommand` in `render.yaml` may not be honored** on this service. Blueprint sync has been unreliable — runtime behavior must come from Dockerfile `CMD`/`ENTRYPOINT`, not `render.yaml` overrides.
- **Shell tab requires a healthy container.** If PID 1 is crashing, the Shell tab is unavailable. Use the debug path below to break the loop.
- **No output for >2 min after `Setting WEB_CONCURRENCY=8`** in deploy logs almost always means the container crashed before producing stdout, or Render is still pulling the image. Don't assume "stuck" means "hanging."
- **Health check is `/health`** — must return 2xx on port 3000.

## Debug path

When the container won't stay up, swap `CMD` to use `debug-start.sh`:

```dockerfile
COPY debug-start.sh /debug-start.sh
RUN chmod +x /debug-start.sh
CMD ["/debug-start.sh"]
```

What it does:
- Binds port 3000 with a tiny Node HTTP server → Render goes Live → Shell tab unlocks
- `tail -f /dev/null` keeps PID 1 alive forever → no restart loop
- `set -x`, full env dump, listings of all candidate `openclaw` binary locations
- Tees everything to `/data/debug.log` so the record survives even if Render drops log lines

Once Live, in the Shell tab:
```sh
cat /data/debug.log
echo $PATH
ls /app/node_modules/.bin | grep -i claw
alphaclaw start          # reproduce the real failure
```

Restore `CMD ["alphaclaw", "start"]` after diagnosis.

## What NOT to do

- Don't patch `node_modules/@chrysb/alphaclaw/` — gets blown away on every `npm install`. Fix at the Dockerfile/env layer instead.
- Don't rely on `dockerCommand` in `render.yaml` to override `CMD` — Blueprint sync may silently ignore it. Use Dockerfile `CMD`.
- Don't drop `ENV PATH="/app/node_modules/.bin:$PATH"` — it's load-bearing for alphaclaw's spawn behavior.
- Don't force-push or amend on `main` after a debug detour. Add a new commit on top.
