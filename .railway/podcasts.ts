import { bucket, github, preserve, ref, service } from "railway/iac";

/** Development rollout only; Production requires a separate reviewed promotion. */
export function developmentPodcasts() {
  const media = bucket("Podcast Media", { region: "sjc" });
  const worker = service("Podcast Media Worker", {
    source: github("Stygian-Tech/the-social-wire", { branch: "dev", rootDirectory: "/" }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "/services/podcast-worker/Dockerfile",
      watchPatterns: [
        "/.railway/**",
        "/services/podcast-worker/**",
        "/database/migrations/**",
        "/services/jetstream-ingest/cmd/schema-ready/**",
        "/services/jetstream-ingest/internal/schemaready/**",
        "/services/jetstream-ingest/go.mod",
        "/services/jetstream-ingest/go.sum",
        "/package.json",
        "/bun.lock",
      ],
    },
    deploy: {
      healthcheckPath: "/startupz",
      healthcheckTimeout: 120,
      restartPolicyType: "ALWAYS",
    },
    replicas: { sfo: 1 },
    env: {
      APP_ENV: "dev",
      PORT: "8080",
      DATABASE_URL: preserve(),
      DATABASE_MIGRATOR_SERVICE_ID: preserve(),
      PODCASTS_ENABLED: "true",
      PODCAST_PUBLIC_GATEWAY_URL: "https://api.testing.thesocialwire.app",
      PODCAST_S3_ENDPOINT: ref(media, "ENDPOINT"),
      PODCAST_S3_BUCKET: ref(media, "BUCKET"),
      PODCAST_S3_ACCESS_KEY_ID: ref(media, "ACCESS_KEY_ID"),
      PODCAST_S3_SECRET_ACCESS_KEY: ref(media, "SECRET_ACCESS_KEY"),
      PODCAST_S3_REGION: ref(media, "REGION"),
      PODCAST_MEDIA_INTERNAL_SECRET: preserve(),
      PODCAST_BRIDGE_DID: preserve(),
      PODCAST_BRIDGE_PDS_URL: preserve(),
      PODCAST_BRIDGE_IDENTIFIER: preserve(),
      PODCAST_BRIDGE_APP_PASSWORD: preserve(),
    },
  });
  return [media, worker];
}
