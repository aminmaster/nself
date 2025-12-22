# Multi-stage build for SvelteKit

# Multi-stage build for SvelteKit

# Development stage (with hot reload support)
FROM node:20-alpine AS development
WORKDIR /app
ENV NODE_ENV=development
COPY package*.json ./
RUN npm install
# Vite dev server on port 3000 to match Nginx proxy
EXPOSE 3000
CMD ["npx", "vite", "dev", "--host", "0.0.0.0", "--port", "3000"]

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
COPY --from=builder /app/build ./build
COPY --from=builder /app/package*.json ./
RUN npm install --production
EXPOSE 3000
CMD ["node", "build/index.js"]
