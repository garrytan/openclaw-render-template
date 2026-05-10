#!/bin/bash
LOGFILE=/data/debug.log
mkdir -p /data
exec > >(tee -a "$LOGFILE") 2>&1
set -x

echo "===== BOOT $(date -u +%FT%TZ) pid=$$ ====="
echo "whoami=$(whoami) pwd=$(pwd)"
echo "PATH=$PATH"
echo "--- /usr/bin/openclaw ---"
ls -la /usr/bin/openclaw 2>&1 || echo "absent"
echo "--- /usr/local/bin/openclaw ---"
ls -la /usr/local/bin/openclaw 2>&1 || echo "absent"
echo "--- /app/node_modules/.bin (claw matches) ---"
ls -la /app/node_modules/.bin/ 2>&1 | grep -i claw || echo "no matches"
echo "--- env ---"
env | sort
echo "===== END BOOT INFO ====="

node -e "require('http').createServer((_,r)=>r.end('ok')).listen(3000,'0.0.0.0',()=>{console.log('LISTENER UP on port 3000');process.stdout.write('');})" &
NODE_PID=$!
echo "node listener bg pid=$NODE_PID"

# Keep PID 1 alive forever, regardless of node exit
exec tail -f /dev/null
