import type { EnvironmentName } from "@/lib/operations-types"

export function operationsEnvironment(): EnvironmentName {
  const value = (process.env.NEXT_PUBLIC_APP_ENV ?? process.env.APP_ENV)?.trim().toLowerCase()
  if (!value) throw new Error("APP_ENV is required and must be exactly dev or prod")
  if (value !== "dev" && value !== "prod")
    throw new Error(`APP_ENV must be exactly dev or prod; received ${value}`)
  return value
}
