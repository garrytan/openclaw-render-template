FROM node:22-slim

RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

RUN printf '#!/bin/sh\nexec /app/node_modules/.bin/openclaw "$@"\n' > /usr/bin/openclaw \
 && printf '#!/bin/sh\nexec /app/node_modules/.bin/alphaclaw "$@"\n' > /usr/bin/alphaclaw \
 && chmod +x /usr/bin/openclaw /usr/bin/alphaclaw \
 && ln -sf /app/node_modules/.bin/openclaw /usr/local/bin/openclaw \
 && ln -sf /app/node_modules/.bin/alphaclaw /usr/local/bin/alphaclaw \
 && /usr/bin/openclaw --version

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

RUN mkdir -p /data

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["alphaclaw", "start"]
