FROM swift:6.2.4-jammy AS builder

WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

COPY packages/swift/SocialWireRedis/Package.swift packages/swift/SocialWireRedis/Package.resolved* packages/swift/SocialWireRedis/
COPY packages/swift/SocialWireRedis/Sources packages/swift/SocialWireRedis/Sources
COPY packages/swift/SocialWireRedis/Tests packages/swift/SocialWireRedis/Tests

COPY packages/swift/ThinAppViewCore/Package.swift packages/swift/ThinAppViewCore/Package.resolved* packages/swift/ThinAppViewCore/
COPY packages/swift/ThinAppViewCore/Sources packages/swift/ThinAppViewCore/Sources
COPY packages/swift/ThinAppViewCore/Tests packages/swift/ThinAppViewCore/Tests

COPY packages/swift/GatewayCore/Package.swift packages/swift/GatewayCore/Package.resolved* packages/swift/GatewayCore/
COPY packages/swift/GatewayCore/Sources packages/swift/GatewayCore/Sources
COPY packages/swift/GatewayCore/Tests packages/swift/GatewayCore/Tests

COPY packages/swift/OperationsCore/Package.swift packages/swift/OperationsCore/Package.resolved* packages/swift/OperationsCore/
COPY packages/swift/OperationsCore/Sources packages/swift/OperationsCore/Sources
COPY packages/swift/OperationsCore/Tests packages/swift/OperationsCore/Tests

COPY packages/swift/WireCore/Package.swift packages/swift/WireCore/Package.resolved* packages/swift/WireCore/
COPY packages/swift/WireCore/Sources packages/swift/WireCore/Sources
COPY packages/swift/WireCore/Tests packages/swift/WireCore/Tests

COPY services/appview/Package.swift services/appview/Package.resolved* services/appview/
COPY services/appview/Sources services/appview/Sources
COPY services/appview/Tests services/appview/Tests

WORKDIR /src/services/appview
RUN swift package resolve
RUN swift build -c release --product AppView

FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libssl3 libcurl4 libsqlite3-0 libicu70 libxml2 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/services/appview/.build/release/AppView /usr/local/bin/AppView
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/AppView
EXPOSE 8081
RUN useradd --system --no-create-home appuser
USER appuser
ENTRYPOINT ["AppView"]
