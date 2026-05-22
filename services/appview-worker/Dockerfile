FROM swift:6.1-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources
COPY packages/swift/ThinAppViewCore/Tests packages/swift/ThinAppViewCore/Tests

COPY services/appview-worker/Package.swift services/appview-worker/Package.resolved* services/appview-worker/
COPY services/appview-worker/Sources services/appview-worker/Sources
COPY services/appview-worker/Tests services/appview-worker/Tests

WORKDIR /src/services/appview-worker
RUN swift package resolve
RUN swift build -c release --product AppViewWorker

FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libssl3 libcurl4 libsqlite3-0 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/services/appview-worker/.build/release/AppViewWorker /usr/local/bin/AppViewWorker
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/AppViewWorker
RUN useradd --system --no-create-home appuser
USER appuser
ENTRYPOINT ["AppViewWorker"]
