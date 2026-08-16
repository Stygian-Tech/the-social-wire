FROM ubuntu:22.04

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates postgresql-client \
  && rm -rf /var/lib/apt/lists/*

COPY database/migrations /app/database/migrations
COPY scripts/apply-database-migrations.sh /usr/local/bin/apply-database-migrations

RUN chmod +x /usr/local/bin/apply-database-migrations \
  && useradd --system --no-create-home appuser

ENV MIGRATIONS_DIR=/app/database/migrations
USER appuser
ENTRYPOINT ["/usr/local/bin/apply-database-migrations"]
