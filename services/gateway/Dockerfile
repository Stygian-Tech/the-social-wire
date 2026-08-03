FROM swift:6.2.4-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources
COPY packages/swift/ThinAppViewCore/Tests packages/swift/ThinAppViewCore/Tests

COPY packages/swift/GatewayCore/Package.swift packages/swift/GatewayCore/Package.resolved* packages/swift/GatewayCore/
COPY packages/swift/GatewayCore/Sources packages/swift/GatewayCore/Sources
COPY packages/swift/GatewayCore/Tests packages/swift/GatewayCore/Tests

COPY packages/swift/OperationsCore/Package.swift packages/swift/OperationsCore/Package.resolved* packages/swift/OperationsCore/
COPY packages/swift/OperationsCore/Sources packages/swift/OperationsCore/Sources
COPY packages/swift/OperationsCore/Tests packages/swift/OperationsCore/Tests

COPY services/gateway/Package.swift services/gateway/Package.resolved* services/gateway/
COPY services/gateway/Sources services/gateway/Sources
COPY services/gateway/Tests services/gateway/Tests

WORKDIR /src/services/gateway
RUN swift package resolve
RUN swift build -c release --product Gateway

FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libssl3 libcurl4 libsqlite3-0 libicu70 libxml2 ca-certificates postgresql-client \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/services/gateway/.build/release/Gateway /usr/local/bin/Gateway
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux
COPY database/migrations /app/database/migrations
COPY scripts/apply-database-migrations.sh /usr/local/bin/apply-database-migrations

RUN chmod +x /usr/local/bin/Gateway /usr/local/bin/apply-database-migrations
ENV MIGRATIONS_DIR=/app/database/migrations
EXPOSE 8080
RUN useradd --system --no-create-home appuser
USER appuser
ENTRYPOINT ["Gateway"]
