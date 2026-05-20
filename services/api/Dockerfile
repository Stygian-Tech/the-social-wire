# ── Build stage ───────────────────────────────────────────────────────────────
FROM swift:6.1-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources

COPY services/api/Package.swift services/api/Package.resolved* services/api/
COPY services/api/Sources services/api/Sources

WORKDIR /src/services/api
RUN swift package resolve
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

COPY --from=builder /src/services/api/.build/release/App /usr/local/bin/App
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/App

EXPOSE 8080

RUN useradd --system --no-create-home appuser
USER appuser

ENTRYPOINT ["App"]
