FROM golang:1.26-bookworm AS builder

WORKDIR /src/services/jetstream-ingest
# Resolve the shared Go package through the repository-local replace directive.
COPY packages/go/ /src/packages/go/
COPY services/jetstream-ingest/go.mod services/jetstream-ingest/go.sum ./
RUN go mod download
COPY services/jetstream-ingest/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/jetstream-ingest ./cmd/jetstream-ingest

RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/schema-ready ./cmd/schema-ready
COPY database/migrations /src/database/migrations
RUN /out/schema-ready --generate-manifest /src/database/migrations > /out/required-migrations.txt

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/jetstream-ingest /usr/local/bin/jetstream-ingest
EXPOSE 8080
COPY --from=builder /out/schema-ready /usr/local/bin/schema-ready
COPY --from=builder /out/required-migrations.txt /etc/socialwire/required-migrations.txt
ENTRYPOINT ["/usr/local/bin/schema-ready", "--", "/usr/local/bin/jetstream-ingest"]
