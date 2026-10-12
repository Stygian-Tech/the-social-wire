const tabs = new Set(["home", "explore", "notifications", "messages", "bookmarks", "lists", "feeds", "saved", "archive", "wire", "circle", "finance", "sports", "subscribed", "following", "podcasts", "articles", "live-post", "livestream", "brand-accounts", "analytics", "profile", "content-calendar"])
const record = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value)
const count = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0
const date = (value: unknown) => typeof value === "string" && Number.isFinite(Date.parse(value))
export function assertTabUsage(value: unknown): void {
  const fail = () => { throw new Error("Operations tab usage failed runtime contract validation") }
  if (!record(value)) return fail()
  if ((value.sourceEnvironment !== undefined && !["local", "dev", "prod"].includes(String(value.sourceEnvironment))) || !date(value.observedAt) || (value.trackingStart !== null && !date(value.trackingStart)) || !count(value.dau) || !count(value.wau) || !count(value.mau) || value.dau > value.wau || value.wau > value.mau || !Array.isArray(value.tabs) || value.tabs.length > tabs.size || Object.keys(value).some(key => !["sourceEnvironment", "observedAt", "trackingStart", "dau", "wau", "mau", "tabs"].includes(key))) return fail()
  const seen = new Set<string>()
  for (const row of value.tabs) {
    if (!record(row) || typeof row.tab !== "string" || !tabs.has(row.tab) || seen.has(row.tab) || !count(row.dau) || !count(row.wau) || !count(row.mau) || !count(row.opens) || typeof row.dwellMs !== "number" || !Number.isFinite(row.dwellMs) || row.dwellMs < 0 || row.dau > row.wau || row.wau > row.mau || row.mau > value.mau || Object.keys(row).some(key => !["tab", "dau", "wau", "mau", "opens", "dwellMs"].includes(key))) return fail()
    seen.add(row.tab)
  }
}
