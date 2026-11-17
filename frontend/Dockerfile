FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.js ./
COPY public ./public
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --retries=5 CMD ["node","-e","fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
CMD ["node","server.js"]
