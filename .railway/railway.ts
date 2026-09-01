import { defineRailway, github, preserve, project, service } from "railway/iac";

export const partial = "indexing-consolidation";

const repository = "Stygian-Tech/the-social-wire";

const developmentProfile = {
  appEnvironment: "dev",
  branch: "dev",
  ingressRegion: "us-west2",
  workerRegion: "us-west2",
  projectionReplicas: 2,
  appViewGeneration: "jetstream-v2-us-west-v2",
  ingress: {
    JETSTREAM_APPVIEW_BOOTSTRAP_AFTER_SEQ: "24790001258",
    JETSTREAM_APPVIEW_ENABLED: "true",
    JETSTREAM_APPVIEW_SOURCE_GENERATION: "jetstream-v2-us-west-v2",
    JETSTREAM_WIRE_BOOTSTRAP_AFTER_SEQ: "24941037520",
    JETSTREAM_WIRE_ENABLED: "true",
    JETSTREAM_WIRE_ADMISSION_BURST_EVENTS: "1",
    JETSTREAM_WIRE_ADMISSION_RATE_PER_SECOND: "3",
    JETSTREAM_WIRE_SOURCE_GENERATION: "wire-global-v4-dev-live-20260830",
  },
  projection: {
    POSTGRES_MAX_CONNECTIONS: "8",
    THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY: "16",
    WIRE_FEED_MODE: "shadow",
    WIRE_INBOX_CONCURRENCY: "24",
    WIRE_POSTGRES_MAX_CONNECTIONS: "12",
  },
  coordinator: {
    POSTGRES_MAX_CONNECTIONS: "16",
    THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY: "32",
    WIRE_FEED_MODE: "shadow",
    WIRE_INBOX_CONCURRENCY: "48",
    WIRE_POSTGRES_MAX_CONNECTIONS: "24",
  },
  wireCleanupBatchSize: "20000",
  wireCleanupIdleMilliseconds: "100",
} as const;

const productionWireSourceGenerations = [
  "wire-global-v1-prod-live-v1",
  "wire-global-v3-prod-live-v1",
  "wire-global-v4-prod-live-tail-v1",
  "wire-global-v5-prod-live-tail-v1",
  "wire-global-v6-prod-publication-live-v1",
  "wire-global-v7-prod-publication-live-tail-v1",
  "wire-global-v8-prod-external-live-v1",
  "wire-global-v8-prod-publication-live-tail-v1",
].join(",");

const productionProfile = {
  appEnvironment: "prod",
  branch: "main",
  ingressRegion: "us-west2",
  workerRegion: "sfo",
  projectionReplicas: 4,
  appViewGeneration: "jetstream-v2-us-west-v2",
  ingress: {
    JETSTREAM_APPVIEW_BOOTSTRAP_AFTER_SEQ: "24794992678",
    JETSTREAM_APPVIEW_ENABLED: "true",
    JETSTREAM_APPVIEW_SOURCE_GENERATION: "jetstream-v2-us-west-v2",
    JETSTREAM_WIRE_LANES: "external,publication",
    JETSTREAM_WIRE_EXTERNAL_ADMISSION_BURST_EVENTS: "1",
    JETSTREAM_WIRE_EXTERNAL_ADMISSION_RATE_PER_SECOND: "3",
    JETSTREAM_WIRE_EXTERNAL_BOOTSTRAP_AFTER_SEQ: "25324903480",
    JETSTREAM_WIRE_EXTERNAL_DATABASE_MAX_BYTES: "42949672960",
    JETSTREAM_WIRE_EXTERNAL_INBOX_MAX_ROWS: "5000000",
    JETSTREAM_WIRE_EXTERNAL_LEADER_LEASE_NAME:
      "wire-global-v8-prod-external-live-v1",
    JETSTREAM_WIRE_EXTERNAL_REPLAY_DAILY_BYTES: "34359738368",
    JETSTREAM_WIRE_EXTERNAL_REPLAY_INCIDENT_BYTES: "17179869184",
    JETSTREAM_WIRE_EXTERNAL_SOURCE_GENERATION:
      "wire-global-v8-prod-external-live-v1",
    JETSTREAM_WIRE_PUBLICATION_ADMISSION_BURST_EVENTS: "256",
    JETSTREAM_WIRE_PUBLICATION_ADMISSION_RATE_PER_SECOND: "600",
    JETSTREAM_WIRE_PUBLICATION_BOOTSTRAP_AFTER_SEQ: "25265377992",
    JETSTREAM_WIRE_PUBLICATION_COLLECTIONS:
      "site.standard.document,site.standard.entry,site.standard.publication,site.standard.graph.recommend,app.thesocialwire.wireFeedback",
    JETSTREAM_WIRE_PUBLICATION_DATABASE_MAX_BYTES: "85899345920",
    JETSTREAM_WIRE_PUBLICATION_HOST: "jetstream.us-east.bsky.network",
    JETSTREAM_WIRE_PUBLICATION_INBOX_MAX_ROWS: "5000000",
    JETSTREAM_WIRE_PUBLICATION_LEADER_LEASE_NAME:
      "wire-global-v8-prod-publication-live-tail-v1",
    JETSTREAM_WIRE_PUBLICATION_REPLAY_DAILY_BYTES: "274877906944",
    JETSTREAM_WIRE_PUBLICATION_REPLAY_INCIDENT_BYTES: "274877906944",
    JETSTREAM_WIRE_PUBLICATION_SOURCE_GENERATION:
      "wire-global-v8-prod-publication-live-tail-v1",
  },
  projection: {
    POSTGRES_MAX_CONNECTIONS: "8",
    THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY: "8",
    WIRE_FEED_MODE: "api",
    WIRE_INBOX_CONCURRENCY: "52",
    WIRE_INBOX_SOURCE_GENERATIONS: productionWireSourceGenerations,
    WIRE_POSTGRES_MAX_CONNECTIONS: "12",
  },
  coordinator: {
    POSTGRES_MAX_CONNECTIONS: "16",
    THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY: "32",
    WIRE_EXTERNAL_SIGNAL_MODE: "shadow",
    WIRE_FEED_MODE: "visible",
    WIRE_INBOX_CONCURRENCY: "32",
    WIRE_INBOX_SOURCE_GENERATIONS: productionWireSourceGenerations,
    WIRE_METADATA_BATCH_SIZE: "128",
    WIRE_METADATA_CONCURRENCY: "16",
    WIRE_POSTGRES_MAX_CONNECTIONS: "12",
  },
  wireCleanupBatchSize: "5000",
  wireCleanupIdleMilliseconds: "1000",
} as const;

const indexingBuild = {
  builder: "DOCKERFILE" as const,
  dockerfilePath: "/services/indexing-worker/Dockerfile",
  watchPatterns: [
    "/.railway/**",
    "/services/indexing-worker/**",
    "/services/appview-worker/**",
    "/services/wire-worker/**",
    "/packages/swift/ThinAppViewCore/**",
    "/packages/swift/OperationsCore/**",
    "/packages/swift/SocialWireRedis/**",
    "/packages/swift/WireCore/**",
    "/database/migrations/**",
  ],
};

const longRunningDeploy = {
  healthcheckPath: "/startupz",
  healthcheckTimeout: 120,
  restartPolicyType: "ALWAYS" as const,
};

export default defineRailway((context) => {
  const profile = context.isEnvironment("dev")
    ? developmentProfile
    : context.isEnvironment("production")
      ? productionProfile
      : undefined;
  if (!profile) {
    throw new Error(
      "The indexing-consolidation partial is authorized only for Development and Production",
    );
  }

  const appViewWorkerEnvironment = {
    APPVIEW_CACHE_BACKEND: "redis",
    APP_ENV: profile.appEnvironment,
    DATABASE_MIGRATOR_SERVICE_ID: preserve(),
    DATABASE_URL: preserve(),
    ENABLE_THIN_APPVIEW: "true",
    JETSTREAM_SOURCE_GENERATION: profile.appViewGeneration,
    OPERATIONS_RECOVERY_ENABLED: "true",
    OPERATIONS_TELEMETRY_ENABLED: "true",
    REDIS_URL: preserve(),
    TAP_CONSUMER_MODE: "disabled",
    THIN_APPVIEW_INGESTION_INBOX_LEASE_SECONDS: "60",
    THIN_APPVIEW_INGESTION_INBOX_POLL_MILLISECONDS: "250",
    THIN_APPVIEW_JETSTREAM_MODE: "v2_authoritative",
    THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED: "false",
    THIN_APPVIEW_REPOSITORY_RESTORE_TIMEOUT_SECONDS: "120",
    WIRE_ACTOR_HMAC_SECRET: preserve(),
    WIRE_INBOX_BATCH_SIZE: "5000",
    WIRE_INBOX_CLEANUP_BATCH_SIZE: profile.wireCleanupBatchSize,
    WIRE_INBOX_CLEANUP_ENABLED: "true",
    WIRE_INBOX_CLEANUP_IDLE_MILLISECONDS: profile.wireCleanupIdleMilliseconds,
    WIRE_INBOX_IDLE_MILLISECONDS: "250",
  } as const;

  const ingressController = service("Ingress Controller", {
    source: github(repository, { branch: profile.branch, rootDirectory: "/" }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "/services/jetstream-ingest/Dockerfile",
      watchPatterns: [
        "/.railway/**",
        "/services/jetstream-ingest/**",
        "/database/migrations/**",
      ],
    },
    deploy: longRunningDeploy,
    replicas: { [profile.ingressRegion]: 2 },
    env: {
      APP_ENV: profile.appEnvironment,
      DATABASE_MIGRATOR_SERVICE_ID: preserve(),
      DATABASE_URL: preserve(),
      JETSTREAM_API_KEY: preserve(),
      ...profile.ingress,
    },
  });

  const projectionPool = service("Projection Pool", {
    source: github(repository, { branch: profile.branch, rootDirectory: "/" }),
    build: indexingBuild,
    deploy: longRunningDeploy,
    replicas: { [profile.workerRegion]: profile.projectionReplicas },
    env: {
      ...appViewWorkerEnvironment,
      ...profile.projection,
      INDEXING_WORKER_ROLE: "projection",
      WIRE_INBOX_CLEANUP_ENABLED: "false",
    },
  });

  const coordinator = service("Coordinator", {
    source: github(repository, { branch: profile.branch, rootDirectory: "/" }),
    build: indexingBuild,
    deploy: longRunningDeploy,
    replicas: { [profile.workerRegion]: 2 },
    env: {
      ...appViewWorkerEnvironment,
      ...profile.coordinator,
      INDEXING_WORKER_ROLE: "coordinator",
    },
  });

  return project("The Social Wire", {
    resources: [ingressController, projectionPool, coordinator],
  });
});
