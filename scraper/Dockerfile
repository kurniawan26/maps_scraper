FROM mcr.microsoft.com/playwright:v1.59.1-noble

ENV NODE_ENV=production \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

WORKDIR /app

# Browser sudah ada di dalam image, jadi install paket saja
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src

USER pwuser
EXPOSE 3000
CMD ["node", "src/server.js"]
