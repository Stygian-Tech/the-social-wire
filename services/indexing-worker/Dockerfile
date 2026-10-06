FROM golang:1.26-bookworm AS schema-ready-builder
WORKDIR /src/services/jetstream-ingest
COPY packages/go/go.mod packages/go/go.sum /src/packages/go/
COPY services/jetstream-ingest/go.mod services/jetstream-ingest/go.sum ./
RUN go mod download
COPY services/jetstream-ingest/cmd/schema-ready ./cmd/schema-ready
COPY services/jetstream-ingest/internal/schemaready ./internal/schemaready
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/schema-ready ./cmd/schema-ready
COPY database/migrations /src/database/migrations
RUN /out/schema-ready --generate-manifest /src/database/migrations > /out/required-migrations.txt

FROM swift:6.2.4-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/SocialWireRedis/Package.swift packages/swift/SocialWireRedis/Package.resolved* packages/swift/SocialWireRedis/
COPY packages/swift/SocialWireRedis/Sources packages/swift/SocialWireRedis/Sources

COPY packages/swift/OperationsCore/Package.swift packages/swift/OperationsCore/Package.resolved* packages/swift/OperationsCore/
COPY packages/swift/OperationsCore/Sources packages/swift/OperationsCore/Sources

COPY packages/swift/ReadStateCore packages/swift/ReadStateCore

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources

COPY packages/swift/WireCore/Package.swift packages/swift/WireCore/Package.resolved* packages/swift/WireCore/
COPY packages/swift/WireCore/Sources packages/swift/WireCore/Sources

COPY packages/swift/FinanceCore/Package.swift packages/swift/FinanceCore/Package.resolved* packages/swift/FinanceCore/
COPY packages/swift/FinanceCore/Sources packages/swift/FinanceCore/Sources
COPY packages/swift/SportsCore packages/swift/SportsCore

COPY services/appview-worker/Package.swift services/appview-worker/Package.resolved* services/appview-worker/
COPY services/appview-worker/Sources services/appview-worker/Sources

COPY services/wire-worker/Package.swift services/wire-worker/Package.resolved* services/wire-worker/
COPY services/wire-worker/Sources services/wire-worker/Sources

COPY services/indexing-worker/Package.swift services/indexing-worker/Package.resolved* services/indexing-worker/
COPY services/indexing-worker/Sources services/indexing-worker/Sources
COPY services/indexing-worker/Tests services/indexing-worker/Tests

WORKDIR /src/services/indexing-worker
RUN swift package resolve
RUN swift build -c release --product IndexingWorker

FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libssl3 libcurl4 libsqlite3-0 libicu70 libxml2 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/services/indexing-worker/.build/release/IndexingWorker /usr/local/bin/IndexingWorker
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/IndexingWorker
RUN useradd --system --no-create-home appuser
USER appuser
EXPOSE 8080
COPY --from=schema-ready-builder /out/schema-ready /usr/local/bin/schema-ready
COPY --from=schema-ready-builder /out/required-migrations.txt /etc/socialwire/required-migrations.txt
ENTRYPOINT ["/usr/local/bin/schema-ready", "--", "/usr/local/bin/IndexingWorker"]
