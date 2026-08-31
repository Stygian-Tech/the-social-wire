FROM swift:6.2.4-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/SocialWireRedis/Package.swift packages/swift/SocialWireRedis/Package.resolved* packages/swift/SocialWireRedis/
COPY packages/swift/SocialWireRedis/Sources packages/swift/SocialWireRedis/Sources

COPY packages/swift/OperationsCore/Package.swift packages/swift/OperationsCore/Package.resolved* packages/swift/OperationsCore/
COPY packages/swift/OperationsCore/Sources packages/swift/OperationsCore/Sources

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources

COPY packages/swift/WireCore/Package.swift packages/swift/WireCore/Package.resolved* packages/swift/WireCore/
COPY packages/swift/WireCore/Sources packages/swift/WireCore/Sources

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
ENTRYPOINT ["IndexingWorker"]
