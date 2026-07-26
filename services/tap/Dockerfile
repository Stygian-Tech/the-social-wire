FROM golang:1.26-bookworm AS builder

ARG INDIGO_COMMIT=dfe5578fd537e71dd1ed884dd09b876dd768dfd5

RUN apt-get update \
  && apt-get install -y --no-install-recommends git gcc libc6-dev libsqlite3-dev ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone https://github.com/bluesky-social/indigo.git . \
  && git checkout --detach "$INDIGO_COMMIT"
RUN CGO_ENABLED=1 go build -trimpath -ldflags='-s -w' -o /out/tap ./cmd/tap

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --no-create-home tap

COPY --from=builder /out/tap /usr/local/bin/tap

USER tap
EXPOSE 2480
ENTRYPOINT ["/usr/local/bin/tap", "run"]
