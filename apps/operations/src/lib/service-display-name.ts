export function serviceDisplayName(service: string): string {
  return service === "appview-worker" ? "Charybdis" : service
}
