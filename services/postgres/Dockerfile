# Preserve Railway's SSL, volume lock, upgrade and backup implementation.
FROM ghcr.io/railwayapp-templates/postgres-ssl:18@sha256:469c779c7c57ec6bad4670a0a3cb5a830aa6e0ce4f3707137608de5223a5041c
COPY --chmod=755 services/postgres/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
# Overriding ENTRYPOINT clears the inherited CMD; preserve the vendor arguments.
CMD ["postgres", "-p", "5432", "-c", "listen_addresses=*"]
STOPSIGNAL SIGTERM
