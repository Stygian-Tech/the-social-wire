import {
  defineRailway,
  github,
  preserve,
  project,
  service,
} from "railway/iac";

export const partial = "indexing-consolidation";

const repository = "Stygian-Tech/the-social-wire";
const region = "us-west2";

const appViewWorkerEnvironment = {
  APPVIEW_CACHE_BACKEND: "redis",
  APP_ENV: "dev",
  DATABASE_MIGRATOR_SERVICE_ID: preserve(),
  DATABASE_URL: preserve(),
  ENABLE_THIN_APPVIEW: "true",
  JETSTREAM_SOURCE_GENERATION: "jetstream-v2-us-west-v2",
  OPERATIONS_RECOVERY_ENABLED: "true",
  REDIS_URL: preserve(),
  THIN_APPVIEW_JETSTREAM_MODE: "v2_authoritative",
  THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED: "false",
  WIRE_ACTOR_HMAC_SECRET: preserve(),
  WIRE_FEED_MODE: "shadow",
  WIRE_INBOX_BATCH_SIZE: "5000",
  WIRE_INBOX_CLEANUP_BATCH_SIZE: "20000",
  WIRE_INBOX_CLEANUP_ENABLED: "true",
  WIRE_INBOX_CLEANUP_IDLE_MILLISECONDS: "100",
  WIRE_INBOX_IDLE_MILLISECONDS: "250",
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
  // Production promotion is intentionally fail-closed until the Development
  // soak has passed and a separate source change enables the production graph.
  if (!context.isEnvironment("dev")) {
    return project("The Social Wire", { resources: [] });
  }

  const ingressController = service("Ingress Controller", {
    source: github(repository, { branch: "dev", rootDirectory: "/" }),
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
    replicas: { [region]: 2 },
    env: {
      APP_ENV: "dev",
      DATABASE_MIGRATOR_SERVICE_ID: preserve(),
      DATABASE_URL: preserve(),
      JETSTREAM_API_KEY: preserve(),
      JETSTREAM_APPVIEW_BOOTSTRAP_AFTER_SEQ: "24790001258",
      JETSTREAM_APPVIEW_ENABLED: "true",
      JETSTREAM_APPVIEW_SOURCE_GENERATION: "jetstream-v2-us-west-v2",
      JETSTREAM_WIRE_BOOTSTRAP_AFTER_SEQ: "24924866033",
      JETSTREAM_WIRE_ENABLED: "true",
      JETSTREAM_WIRE_SOURCE_GENERATION: "wire-global-v1-dev-1h-20260820",
    },
  });

  const projectionPool = service("Projection Pool", {
    source: github(repository, { branch: "dev", rootDirectory: "/" }),
    build: indexingBuild,
    deploy: longRunningDeploy,
    replicas: { [region]: 2 },
    env: {
      ...appViewWorkerEnvironment,
      INDEXING_WORKER_ROLE: "projection",
      POSTGRES_MAX_CONNECTIONS: "8",
      THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY: "16",
      WIRE_INBOX_CONCURRENCY: "24",
      WIRE_POSTGRES_MAX_CONNECTIONS: "12",
    },
  });

  const coordinator = service("Coordinator", {
    source: github(repository, { branch: "dev", rootDirectory: "/" }),
    build: indexingBuild,
    deploy: longRunningDeploy,
    replicas: { [region]: 2 },
    env: {
      ...appViewWorkerEnvironment,
      INDEXING_WORKER_ROLE: "coordinator",
      POSTGRES_MAX_CONNECTIONS: "16",
      THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY: "32",
      WIRE_INBOX_CONCURRENCY: "48",
      WIRE_POSTGRES_MAX_CONNECTIONS: "24",
    },
  });

  return project("The Social Wire", {
    resources: [ingressController, projectionPool, coordinator],
  });
});
