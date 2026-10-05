import type { SportsEntity, SportsFeedDefinition } from "@/lib/sportsFeedClient";
import { displaySportsEntityName, displaySportsFeedTitle, displaySportsGroupPath, sportsFeedSearchText } from "@/lib/sportsDisplayNames";
import type { SportsPickerFeedDefinition } from "@/lib/sportsFeedPickerGroups";

export type SportsPickerNode = { id: string; label: string; children: SportsPickerNode[]; feeds: SportsFeedDefinition[] };
const categories = new Set(["Sports", "Competitions", "Teams", "National Sides", "NCAA Teams", "Programs", "Athletes", "Drivers", "Other"]);

/** IDs and reviewed relationships establish hierarchy; display labels never establish identity. */
export function sportsFeedPickerTree(definitions: readonly SportsFeedDefinition[], entities: readonly SportsEntity[], locale?: string): SportsPickerNode {
  const root: SportsPickerNode = {id:"root",label:"Sports",children:[],feeds:[]};
  const byID = new Map(entities.map(entity => [entity.id, entity]));
  const sportsByName = new Map<string, SportsEntity>();
  for (const entity of entities) {
    if (entity.active && entity.kind === "sport" && !sportsByName.has(entity.name)) sportsByName.set(entity.name, entity);
  }
  for (const feed of definitions) {
    if (feed.kind === "global") { root.feeds.push(feed); continue; }
    const entity = byID.get(feed.entityIDs[0] ?? "");
    const canonicalSport = entity?.kind === "sport" ? entity : entity?.sportID ? byID.get(entity.sportID) : undefined;
    const reviewedPath = feed.groupPath ?? entity?.groupPath;
    const relationshipPath = entity?.competitionIDs.flatMap(id => {const competition=byID.get(id);return competition?.active && competition.kind === "competition" ? [competition.name] : [];}).slice(0,1) ?? [];
    const rawPath = (reviewedPath?.length ? reviewedPath : relationshipPath).filter(part => part.trim() && !categories.has(part));
    // A reviewed umbrella can organize multiple canonical sports without changing their identities.
    const sport = sportsByName.get(rawPath[0] ?? "") ?? canonicalSport;
    const localizedPath = displaySportsGroupPath(rawPath, locale);
    const sportLabel = sport ? displaySportsEntityName(sport, locale).replaceAll("\u00a0", " ") : undefined;
    const path: {key:string;label:string}[] = sport ? [{key:sport.id,label:sportLabel!}] : [];
    for (let i = 0; i < rawPath.length; i++) {
      if (rawPath[i] === sport?.name || localizedPath[i] === sportLabel) continue;
      path.push({key:rawPath[i]!,label:localizedPath[i]!});
    }
    if (!path.length) path.push({key:feed.kind === "sport" ? feed.entityIDs[0] ?? feed.id : "other",label:feed.kind === "sport" ? displaySportsFeedTitle(feed, locale) : "Other Interests"});
    if (feed.kind === "competition" && path.at(-1)?.label !== feed.title && !rawPath.includes("NCAA")) path.push({key:entity?.name ?? feed.title,label:feed.title});
    let node = root;
    for (const part of path) {
      const id = JSON.stringify([node.id, part.key]);
      let child = node.children.find(candidate => candidate.id === id);
      if (!child) { child = {id,label:part.label,children:[],feeds:[]}; node.children.push(child); }
      node = child;
    }
    node.feeds.push(feed);
  }
  function sort(node: SportsPickerNode) {
    node.children.sort((a,b)=>a.label.localeCompare(b.label, locale, {numeric:true}));
    node.feeds.sort((a,b)=>displaySportsFeedTitle(a,locale).localeCompare(displaySportsFeedTitle(b,locale), locale, {numeric:true}));
    node.children.forEach(sort);
  }
  sort(root);
  return root;
}

export function sportsPickerSearch(definitions: readonly SportsPickerFeedDefinition[], search: string, locale?: string, limit = 50) {
  const query = search.trim().toLocaleLowerCase();
  const matches = definitions.filter(feed => feed.kind !== "global" && sportsFeedSearchText(feed,locale).includes(query));
  return {feeds:matches.slice(0,limit),total:matches.length};
}
