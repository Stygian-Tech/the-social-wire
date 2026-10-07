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

FROM golang:1.26-bookworm AS builder
WORKDIR /src/services/appview
COPY packages/go/go.mod packages/go/go.sum /src/packages/go/
COPY services/appview/go.mod services/appview/go.sum ./
RUN go mod download
COPY packages/go /src/packages/go
COPY services/appview/cmd ./cmd
COPY services/appview/internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/AppView ./cmd/appview

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --no-create-home appuser
COPY --from=builder /out/AppView /usr/local/bin/AppView
COPY --from=schema-ready-builder /out/schema-ready /usr/local/bin/schema-ready
COPY --from=schema-ready-builder /out/required-migrations.txt /etc/socialwire/required-migrations.txt
USER appuser
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/schema-ready", "--", "/usr/local/bin/AppView"]
