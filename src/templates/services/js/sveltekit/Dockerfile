# Multi-stage build for SvelteKit

# Multi-stage build for SvelteKit

# Development stage (with hot reload support)
FROM node:20-alpine AS development
WORKDIR /app
ARG PORT=3000
ENV PORT=${PORT}
ENV NODE_ENV=development
COPY package*.json ./
RUN npm install
# Vite dev server on configured port
EXPOSE ${PORT}
CMD npx vite dev --host 0.0.0.0 --port ${PORT}

# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

# Production stage
FROM node:20-alpine AS production
WORKDIR /app
ARG PORT=3000
ENV PORT=${PORT}
COPY --from=builder /app/build ./build
COPY --from=builder /app/package*.json ./
RUN npm install --omit=dev --no-scripts
EXPOSE ${PORT}
CMD ["node", "build/index.js"]
