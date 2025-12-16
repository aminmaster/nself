FROM python:3.12-slim

WORKDIR /app

# Install system dependencies (curl for healthcheck)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install uv for fast package management
RUN pip install uv

# Copy dependency definition
COPY pyproject.toml .

# Install dependencies
RUN uv pip install --system .

# Copy source code
COPY src/ ./src/

# Expose port
EXPOSE 8090

# Run commands
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8090", "--reload"]
