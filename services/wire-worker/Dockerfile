FROM swift:6.2.4-jammy AS builder

WORKDIR /src

COPY packages/swift/WireCore/Package.swift packages/swift/WireCore/Package.resolved* packages/swift/WireCore/
COPY packages/swift/WireCore/Sources packages/swift/WireCore/Sources
COPY packages/swift/WireCore/Tests packages/swift/WireCore/Tests

COPY services/wire-worker/Package.swift services/wire-worker/Package.resolved* services/wire-worker/
COPY services/wire-worker/Sources services/wire-worker/Sources
COPY services/wire-worker/Tests services/wire-worker/Tests

WORKDIR /src/services/wire-worker
RUN swift package resolve
RUN swift build -c release --product WireWorker

FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends libssl3 libcurl4 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/services/wire-worker/.build/release/WireWorker /usr/local/bin/WireWorker
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/WireWorker
RUN useradd --system --no-create-home appuser
USER appuser
EXPOSE 8080
ENTRYPOINT ["WireWorker"]
