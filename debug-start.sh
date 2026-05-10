#!/bin/sh
node -e "require('http').createServer((_,r)=>r.end('ok')).listen(3000,'0.0.0.0',()=>console.log('debug listener up on port 3000'))" &
sleep 3
echo "=== running alphaclaw start ==="
/app/node_modules/.bin/alphaclaw start 2>&1
echo "=== alphaclaw exited with code $? ==="
exec tail -f /dev/null
