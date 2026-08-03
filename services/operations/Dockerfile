FROM swift:6.2.4-jammy AS builder
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libxml2-dev && rm -rf /var/lib/apt/lists/*
COPY packages/swift/ThinAppViewCore packages/swift/ThinAppViewCore
COPY packages/swift/GatewayCore packages/swift/GatewayCore
COPY packages/swift/OperationsCore packages/swift/OperationsCore
COPY services/operations services/operations
WORKDIR /src/services/operations
RUN swift package resolve
RUN swift build -c release --product Operations

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends libssl3 libcurl4 libsqlite3-0 libicu70 libxml2 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/services/operations/.build/release/Operations /usr/local/bin/Operations
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux
RUN useradd --system --no-create-home appuser
USER appuser
EXPOSE 8083
ENTRYPOINT ["Operations"]
