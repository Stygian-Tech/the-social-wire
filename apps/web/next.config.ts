import path from "path";

import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  env: {
    NEXT_PUBLIC_APP_ENV:
      process.env.NEXT_PUBLIC_APP_ENV ?? process.env.APP_ENV ?? "",
  },
  allowedDevOrigins: ["127.0.0.1", "[::1]"],
  async rewrites() {
    return {
      beforeFiles: [
        {
          source: "/client-metadata.json",
          destination: "/api/oauth/web-client-metadata",
        },
      ],
    };
  },
  /** Dev-only: avoid ChunkLoadError when Webpack is slow to emit large route chunks after Fast Refresh. */
  webpack: (config, { dev }) => {
    if (dev && config.output && typeof config.output === "object") {
      config.output.chunkLoadTimeout = 180_000;
    }
    return config;
  },
  /**
   * Monorepo root so Turbopack resolves `next` from the workspace (setting this to only `apps/web`
   * breaks `next build` with package resolution errors). Heavy dev-mode churn from Turbopack is
   * avoided by running `next dev --webpack` in the package `dev` script.
   */
  turbopack: {
    root: path.join(__dirname, "..", ".."),
  },
  async headers() {
    return [
      {
        source: "/client-metadata.json",
        headers: [{ key: "Access-Control-Allow-Origin", value: "*" }],
      },
      {
        source: "/ios-client-metadata.json",
        headers: [{ key: "Access-Control-Allow-Origin", value: "*" }],
      },
    ];
  },
};

export default nextConfig;
