# ── Build stage ───────────────────────────────────────────────────────────────
FROM swift:6.1-jammy AS builder

WORKDIR /app

# GRDB compiles against system SQLite headers
RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev \
  && rm -rf /var/lib/apt/lists/*

# Copy manifest first for layer caching
COPY Package.swift Package.resolved* ./

# Resolve dependencies (cached if manifests unchanged)
RUN swift package resolve

# Copy source
COPY Sources Sources
COPY Tests Tests

# Build release binary
RUN swift build -c release --product App

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libssl3 \
    libcurl4 \
    libsqlite3-0 \
    libicu70 \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/.build/release/App /usr/local/bin/App

# Release binaries link the Swift runtime dynamically (libswiftCore, Concurrency, etc.); copy the
# toolchain libraries from the build image—plain Ubuntu does not ship them.
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

# Ensure the binary is executable
RUN chmod +x /usr/local/bin/App

EXPOSE 8080

# Run as non-root
RUN useradd --system --no-create-home appuser
USER appuser

ENTRYPOINT ["App"]
