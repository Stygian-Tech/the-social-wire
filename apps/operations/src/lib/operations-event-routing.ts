import type { OperationsEvent } from "@/lib/operations-api"

export function eventAffectsRoute(event: OperationsEvent, routeKey: string) {
  const domain = event.type?.split(".", 1)[0]
  if (!domain) return false
  if (routeKey.startsWith("gaps/")) return domain === "gap" || domain === "job"
  if (routeKey.startsWith("backfills/")) return domain === "job" || domain === "gap"
  if (routeKey.startsWith("alerts/")) return domain === "alert" || domain === "command"
  if (routeKey === "commands") return domain === "command"
  if (routeKey === "endpoints") return domain === "endpoint" || domain === "ingestion"
  if (routeKey === "ingestion") return ["ingestion", "gap", "job", "endpoint", "command"].includes(domain)
  if (routeKey === "appview") return ["service", "ingestion", "endpoint", "command"].includes(domain)
  return false
}

export function eventAffectsSupportData(event: OperationsEvent) {
  const domain = event.type?.split(".", 1)[0]
  return domain !== undefined && ["command", "endpoint", "ingestion", "capability"].includes(domain)
}
