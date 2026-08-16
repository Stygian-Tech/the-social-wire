FROM golang:1.26-bookworm AS builder

WORKDIR /src/services/jetstream-ingest
COPY services/jetstream-ingest/go.mod services/jetstream-ingest/go.sum ./
RUN go mod download
COPY services/jetstream-ingest/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/jetstream-ingest ./cmd/jetstream-ingest

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/jetstream-ingest /usr/local/bin/jetstream-ingest
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/jetstream-ingest"]
