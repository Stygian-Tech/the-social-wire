# ── Build stage ───────────────────────────────────────────────────────────────
FROM swift:6.1-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources
COPY packages/swift/ThinAppViewCore/Tests packages/swift/ThinAppViewCore/Tests

COPY services/worker/Package.swift services/worker/Package.resolved* services/worker/
COPY services/worker/Sources services/worker/Sources
COPY services/worker/Tests services/worker/Tests

WORKDIR /src/services/worker
RUN swift package resolve
RUN swift build -c release --product Worker

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

COPY --from=builder /src/services/worker/.build/release/Worker /usr/local/bin/Worker
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/Worker

RUN useradd --system --no-create-home appuser
USER appuser

ENTRYPOINT ["Worker"]
