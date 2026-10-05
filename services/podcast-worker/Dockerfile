FROM golang:1.26-bookworm AS schema-ready-builder
WORKDIR /src/services/jetstream-ingest
COPY services/jetstream-ingest/go.mod services/jetstream-ingest/go.sum ./
RUN go mod download
COPY services/jetstream-ingest/cmd/schema-ready ./cmd/schema-ready
COPY services/jetstream-ingest/internal/schemaready ./internal/schemaready
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/schema-ready ./cmd/schema-ready
COPY database/migrations /src/database/migrations
RUN /out/schema-ready --generate-manifest /src/database/migrations > /out/required-migrations.txt

FROM oven/bun:1.3.14-debian
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json bun.lock ./
COPY apps/web/package.json apps/web/package.json
COPY apps/operations/package.json apps/operations/package.json
COPY packages/read-state/package.json packages/read-state/package.json
COPY packages/lexicons/package.json packages/lexicons/package.json
COPY packages/spec/package.json packages/spec/package.json
COPY services/podcast-worker/package.json services/podcast-worker/package.json
RUN bun install --frozen-lockfile --ignore-scripts
COPY services/podcast-worker services/podcast-worker
USER bun
EXPOSE 8080
COPY --from=schema-ready-builder /out/schema-ready /usr/local/bin/schema-ready
COPY --from=schema-ready-builder /out/required-migrations.txt /etc/socialwire/required-migrations.txt
ENTRYPOINT ["/usr/local/bin/schema-ready", "--", "bun", "services/podcast-worker/src/index.ts"]
