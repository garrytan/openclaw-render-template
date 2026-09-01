FROM node:22-slim

RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini vim screen tmux && rm -rf /var/lib/apt/lists/*

# Pinned exactly, same discipline as the alphaclaw SHA pin: an unpinned
# install floats to latest whenever an earlier layer changes, silently
# shipping an unreviewed claude-code. Bump deliberately and record it.
RUN npm install -g @anthropic-ai/claude-code@2.1.252 && npm cache clean --force

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

RUN printf '#!/bin/sh\nexec /app/node_modules/.bin/openclaw "$@"\n' > /usr/bin/openclaw \
 && printf '#!/bin/sh\nexec /app/node_modules/.bin/alphaclaw "$@"\n' > /usr/bin/alphaclaw \
 && printf '#!/bin/sh\nexec /usr/local/bin/claude "$@"\n' > /usr/bin/claude \
 && chmod +x /usr/bin/openclaw /usr/bin/alphaclaw /usr/bin/claude \
 && ln -sf /app/node_modules/.bin/openclaw /usr/local/bin/openclaw \
 && ln -sf /app/node_modules/.bin/alphaclaw /usr/local/bin/alphaclaw \
 && /usr/bin/openclaw --version \
 && /usr/bin/claude --version

COPY start.sh /start.sh
COPY failure-server.js /failure-server.js
RUN chmod +x /start.sh

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

# Route temp onto the persistent disk instead of the container's ephemeral /tmp.
# OpenClaw is migrating hardcoded /tmp callsites to TMPDIR-aware APIs; any code
# that respects the standard temp env vars will land under /data/tmp.
# NOTE: /data is a runtime-mounted disk, so this build-time mkdir is shadowed at
# runtime — start.sh recreates /data/tmp on boot. Kept here for image self-consistency.
ENV TMPDIR=/data/tmp
ENV TEMP=/data/tmp
ENV TMP=/data/tmp

RUN mkdir -p /data/tmp && chmod 1777 /data/tmp

EXPOSE 3000

# -g: tini signals the ENTIRE process group, so a TERM to PID 1 reaches
# alphaclaw, tee, and any backoff sleep directly from the kernel. This is what
# lets start.sh's supervise loop stay a plain foreground loop with no trap /
# job-control machinery — bash's default TERM disposition is fine because no
# process depends on bash forwarding anything.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/start.sh"]
