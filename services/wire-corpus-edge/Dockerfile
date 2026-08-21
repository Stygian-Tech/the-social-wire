FROM swift:6.2.4-jammy AS builder

WORKDIR /src

COPY packages/swift/WireCore/Package.swift packages/swift/WireCore/Package.resolved* packages/swift/WireCore/
COPY packages/swift/WireCore/Sources packages/swift/WireCore/Sources
COPY packages/swift/WireCore/Tests packages/swift/WireCore/Tests

COPY services/wire-corpus-edge/Package.swift services/wire-corpus-edge/Package.resolved* services/wire-corpus-edge/
COPY services/wire-corpus-edge/Sources services/wire-corpus-edge/Sources
COPY services/wire-corpus-edge/Tests services/wire-corpus-edge/Tests

WORKDIR /src/services/wire-corpus-edge
RUN swift package resolve
RUN swift build -c release --product WireCorpusEdge

FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends libssl3 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/services/wire-corpus-edge/.build/release/WireCorpusEdge /usr/local/bin/WireCorpusEdge
COPY --from=builder /usr/lib/swift/linux /usr/lib/swift/linux

RUN chmod +x /usr/local/bin/WireCorpusEdge
RUN useradd --system --no-create-home appuser
USER appuser
EXPOSE 8080
ENTRYPOINT ["WireCorpusEdge"]
