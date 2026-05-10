FROM node:22-slim

RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

RUN ln -sf /app/node_modules/.bin/openclaw /usr/local/bin/openclaw \
 && ln -sf /app/node_modules/.bin/alphaclaw /usr/local/bin/alphaclaw

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

RUN mkdir -p /data

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["alphaclaw", "start"]
