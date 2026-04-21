FROM node:18-slim

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY index.js .

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', r => r.statusCode === 200 ? process.exit(0) : process.exit(1))"

CMD ["node", "index.js"]