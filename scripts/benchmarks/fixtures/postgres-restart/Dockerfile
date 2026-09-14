# Trial-only image. Production keeps its existing service image and entrypoint.
FROM ghcr.io/railwayapp-templates/postgres-ssl:18@sha256:469c779c7c57ec6bad4670a0a3cb5a830aa6e0ce4f3707137608de5223a5041c
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY --chmod=755 services/postgres/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY scripts/benchmarks/*.py /benchmark/
ENV PYTHONDONTWRITEBYTECODE=1
ENTRYPOINT ["python3", "/benchmark/trial_postgres_supervisor.py"]
CMD []
STOPSIGNAL SIGTERM
