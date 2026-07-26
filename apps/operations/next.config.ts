import type { NextConfig } from "next"
import path from "node:path"

const operatorDids =
  process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS?.trim()
  || process.env.OPERATIONS_OPERATOR_DIDS?.trim()
  || ""

const nextConfig: NextConfig = {
  devIndicators: false,
  env: {
    NEXT_PUBLIC_APP_ENV: process.env.NEXT_PUBLIC_APP_ENV ?? process.env.APP_ENV ?? "",
    NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS: operatorDids,
  },
  turbopack: { root: path.resolve(__dirname, "../..") },
  outputFileTracingRoot: path.resolve(__dirname, "../.."),
  outputFileTracingIncludes: {
    "/**": ["../../docs/runbooks/operations/*.md"],
  },
}

export default nextConfig
