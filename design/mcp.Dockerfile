# The Penpot MCP bridge, built locally.
#
# Upstream publishes ghcr.io/zcube/penpot-mcp-server, but that package is not
# publicly pullable (anonymous manifest requests are denied), so the stack builds
# the server from a pinned commit instead of trusting a registry tag.
#
# The commit is pinned on purpose: update MCP_REF deliberately, not by pulling a
# moving `latest`.
FROM node:22-alpine AS builder
RUN apk add --no-cache git
WORKDIR /src
ARG MCP_REF=389545cfacffaca7465eedac90892f0db92e1f16
RUN git clone --quiet https://github.com/zcube/penpot-mcp-server.git /src \
 && git checkout --quiet "$MCP_REF"
RUN npm ci --ignore-scripts && npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=builder /src/package.json /src/package-lock.json ./
COPY --from=builder /src/dist ./dist
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001 && chown -R nodejs:nodejs /app
USER nodejs
ENV TRANSPORT=http \
    HTTP_PORT=3000
EXPOSE 3000
CMD ["node", "dist/index.js"]
