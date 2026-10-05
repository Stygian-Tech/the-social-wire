import type { SportsEntity, SportsFeedDefinition } from "@/lib/sportsFeedClient";

const soccerRegions = new Set(["US", "CA", "AU", "NZ", "IE", "ZA"]);

/** Use the explicit locale region, never infer location from an IP address or timezone. */
export function sportsUsesSoccer(locale = "en-US"): boolean {
  try {
    const region = new Intl.Locale(locale.replaceAll("_", "-")).region;
    return region ? soccerRegions.has(region) : true;
  } catch {
    return true;
  }
}

function usesUnqualifiedAmericanFootball(locale = "en-US"): boolean {
  try {
    const region = new Intl.Locale(locale.replaceAll("_", "-")).region;
    return !region || region === "US" || region === "CA";
  } catch {
    return true;
  }
}

function sportName(name: string, locale?: string): string {
  if (name === "Football") return sportsUsesSoccer(locale) ? "Soccer" : "Football";
  if (name === "American Football") return usesUnqualifiedAmericanFootball(locale) ? "Football" : "American Football";
  return name;
}

export function displaySportsEntityName(entity: Pick<SportsEntity, "name" | "kind">, locale?: string): string {
  const name = entity.kind === "sport" ? sportName(entity.name, locale) : entity.name;
  return ["sport", "competition"].includes(entity.kind) ? name.replaceAll(" ", "\u00a0") : name;
}

export function displaySportsFeedTitle(feed: Pick<SportsFeedDefinition, "title" | "kind">, locale?: string): string {
  const title = feed.kind === "sport" ? sportName(feed.title, locale) : feed.title;
  return ["sport", "competition"].includes(feed.kind) ? title.replaceAll(" ", "\u00a0") : title;
}

export function displaySportsGroupPath(path: readonly string[], locale?: string): string[] {
  const ncaa = path.some(part => part === "NCAA" || part.startsWith("Division "));
  return path.map(part => part === "Football" && ncaa ? sportName("American Football", locale) : sportName(part, locale));
}

/** Search both familiar display terms and canonical catalog terminology. */
export function sportsFeedSearchText(feed: SportsFeedDefinition & { searchAliases?: readonly string[] }, locale?: string): string {
  const path = feed.groupPath ?? [];
  return [feed.title, displaySportsFeedTitle(feed, locale), feed.description, ...path, ...displaySportsGroupPath(path, locale), ...(feed.searchAliases ?? [])].join(" ").replaceAll("\u00a0", " ").toLocaleLowerCase();
}
