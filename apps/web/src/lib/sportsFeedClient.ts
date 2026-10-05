import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { discoveryGatewayFetch, type WireItem, type WirePage } from "@/lib/wireFeedClient";
import { feedResponseError } from "@/lib/feedResponseError";
export type SportsEntity = { id: string; name: string; kind: string; sportID?: string; competitionIDs: string[]; aliases: string[]; groupPath?: string[]; schoolID?: string; gender?: string; division?: string; abbreviation?: string; active: boolean };
export type SportsItem = { story: WireItem; entities: SportsEntity[]; associations: { entityID: string; confidence: number; prominence: number; resolverVersion: string; evidence: string[] }[]; majorGlobal: boolean; sportIDs?: string[]; competitionIDs?: string[]; materiality: string };
export type SportsPage = Omit<WirePage,"items"> & { items: SportsItem[]; feedId: string; preferenceRevision: string; expiresAt: string; eventsEnabled: boolean };
export type SportsFeedDefinition = { id: string; title: string; kind: string; entityIDs: string[]; description: string; groupPath?: string[] };
export type SportsCatalog = { enabled: boolean; available: boolean; eventsEnabled: boolean; feeds: SportsFeedDefinition[]; entities: SportsEntity[]; version: string };
export type SportsSelection = { reference: string; action: "follow" | "mute"; createdAt: string; updatedAt: string };
export type SportsEvent = { id: string; title: string; competitionID: string; entityIDs: string[]; updatedAt: string; startsAt: string; startTimeKnown?: boolean; status: string; homeName?: string; awayName?: string; homeAbbreviation?: string; awayAbbreviation?: string; homeScore?: string; awayScore?: string };
export type SportsStandingsRow = { id: string; entityID?: string; name: string; rank?: number; played?: number; won?: number; drawn?: number; lost?: number; points?: string; group?: string; zone?: { kind: string; label: string; sourceURL: string } };
export type SportsStandings = { competitionID: string; season: string; sourceURL: string; status: "available" | "empty" | "unavailable"; updatedAt?: string; degraded: boolean; rows: SportsStandingsRow[] };
export type SportsBracketSource = { id: string; competitionID: string; season: string; title: string; url: string; reviewedAt: string; mode: "external" };
export type SportsEvents = { preferredIDs?: string[]; timeZone?: string; bracketSources?: SportsBracketSource[]; eventsLimited?: boolean; events: SportsEvent[]; updatedAt?: string; degraded: boolean; schedulesStatus?: "available" | "empty" | "unavailable"; standings?: SportsStandings[] };
export const SPORTS_SELECTION_COLLECTION = "app.thesocialwire.sports.selection";
async function query<T>(method: string, params: URLSearchParams, oauthSession?: OAuthSession, signal?: AbortSignal): Promise<T> {
 const response = await discoveryGatewayFetch({path:`/xrpc/app.thesocialwire.discovery.${method}?${params}`,oauthSession,signal});
 if (!response.ok) throw await feedResponseError(response,"Sports could not load");
 return response.json() as Promise<T>;
}
export async function getSports(args: {feed?: string; cursor?: string; language?: string; region?: string; refreshSelections?: boolean; oauthSession?: OAuthSession; signal?: AbortSignal}): Promise<SportsPage> {
 const params = new URLSearchParams({feed:args.feed ?? "sports"});
 if(args.cursor) params.set("cursor",args.cursor);
 if(args.language) params.set("lang",args.language);
 if(args.region) params.set("region",args.region);
 if(args.refreshSelections) params.set("refreshSelections","true");
 const page = await query<SportsPage>("getSports",params,args.oauthSession,args.signal);
 if(page.feedId !== (args.feed ?? "sports")) throw new Error("Sports returned a different feed. Try Refresh.");
 return page;
}
export const sportsTopicIsVisible = (showSports: boolean, catalog?: Pick<SportsCatalog,"enabled">) => showSports && catalog?.enabled === true;
export const getSportsCatalog = (signal?: AbortSignal) => query<SportsCatalog>("getSportsCatalog",new URLSearchParams(),undefined,signal);
export const searchSportsEntities = (q: string, signal?: AbortSignal) => query<{entities:SportsEntity[]}>("searchSportsEntities",new URLSearchParams({q}),undefined,signal);
export const getSportsEvents = async (feed: string, signal?: AbortSignal, teamIDs?: readonly string[], context?: { preferredIDs: readonly string[]; timeZone: string }) => {
 const params = new URLSearchParams({feed});
 if (teamIDs !== undefined) params.set("teamIDs", [...new Set(teamIDs)].sort().join(","));
 if (context) { params.set("preferredIDs", [...new Set(context.preferredIDs)].sort().join(",")); params.set("timeZone", context.timeZone); }
 const data = await query<SportsEvents>("getSportsEvents",params,undefined,signal);
 if (context?.preferredIDs.length && (JSON.stringify([...(data.preferredIDs ?? [])].sort()) !== JSON.stringify([...new Set(context.preferredIDs)].sort()) || data.timeZone !== context.timeZone)) throw new Error("Schedules returned a different interest scope. Try Refresh.");
 if (teamIDs !== undefined) {
  const allowed = new Set(teamIDs);
  if (data.events.some(event => !event.entityIDs.some(id => allowed.has(id))) || data.standings?.some(table => table.rows.length > 0 && !table.rows.some(row => row.entityID && allowed.has(row.entityID)))) {
   throw new Error("Team schedules returned a different scope. Try Refresh.");
  }
 }
 return data;
};
export const sportsPreferenceFingerprint = (selections: readonly SportsSelection[]) => JSON.stringify([...new Set(selections.map(s=>`${s.reference}:${s.action}`))].sort());
export async function sportsSelectionKey(reference: string): Promise<string> {
 const hash=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(reference));
 return [...new Uint8Array(hash)].map(b=>b.toString(16).padStart(2,"0")).join("");
}
export async function listSportsSelections(oauth:OAuthSession,did:string):Promise<SportsSelection[]> {
 const agent=createOAuthAgent(oauth); const selections:SportsSelection[]=[]; let cursor:string|undefined;
 do { const page=await agent.com.atproto.repo.listRecords({repo:did,collection:SPORTS_SELECTION_COLLECTION,limit:100,cursor});
 for(const row of page.data.records){ const value=row.value as Partial<SportsSelection>; if(typeof value.reference==="string"&&(value.action==="follow"||value.action==="mute")&&typeof value.createdAt==="string"&&typeof value.updatedAt==="string") selections.push(value as SportsSelection); } cursor=page.data.cursor;
 } while(cursor); return selections;
}
export async function writeSportsSelection(oauth:OAuthSession,did:string,selection:SportsSelection,remove:boolean):Promise<void> {
 const agent=createOAuthAgent(oauth); const rkey=await sportsSelectionKey(selection.reference);
 if(remove) await agent.com.atproto.repo.deleteRecord({repo:did,collection:SPORTS_SELECTION_COLLECTION,rkey});
 else await agent.com.atproto.repo.putRecord({repo:did,collection:SPORTS_SELECTION_COLLECTION,rkey,record:{$type:SPORTS_SELECTION_COLLECTION,...selection}});
}
export function reorderSportsItems(items:readonly SportsItem[],selections:readonly SportsSelection[],personalize=true):SportsItem[] {
 const followed=new Set(selections.filter(s=>s.action==="follow").map(s=>s.reference)); const muted=new Set(selections.filter(s=>s.action==="mute").map(s=>s.reference));
 const broad=(item:SportsItem)=>[...(item.sportIDs??[]),...(item.competitionIDs??[])];
 const direct=(e:SportsEntity)=>["team","national-side","athlete","driver","ncaa-team"].includes(e.kind);
 const eligible=items.filter(item=>{
  const specificMute=item.entities.some(e=>direct(e)&&muted.has(e.id));
  if(specificMute) return false;
  const exception=item.entities.some(e=>direct(e)&&followed.has(e.id));
  return exception || (!broad(item).some(id=>muted.has(id)) && !item.entities.some(e=>muted.has(e.id)|| (!!e.sportID&&muted.has(e.sportID)) || e.competitionIDs.some(id=>muted.has(id))));
 });
 if(!personalize) return eligible;
 const ranked=eligible.map((item,index)=>{
  const personal = item.entities.some(entity => direct(entity) && followed.has(entity.id));
  const competitions = [...(item.competitionIDs ?? []), ...item.entities.flatMap(entity => [...entity.competitionIDs, ...(!direct(entity) && entity.kind !== "sport" ? [entity.id] : [])])];
  const sports = [...(item.sportIDs ?? []), ...item.entities.flatMap(entity => [...(entity.sportID ? [entity.sportID] : []), ...(entity.kind === "sport" ? [entity.id] : [])])];
  const boost = Math.min(.35, (personal ? .25 : 0) + (competitions.some(id => followed.has(id)) ? .1 : 0) + (sports.some(id => followed.has(id)) ? .05 : 0));
  return {item,index,score:(items.length-index)*(1+boost)};
 }).sort((a,b)=>b.score-a.score||a.index-b.index).map(row=>row.item);
 const result:SportsItem[]=[]; while(ranked.length){const global=result.length%5===4?ranked.findIndex(i=>i.majorGlobal):-1; result.push(ranked.splice(global<0?0:global,1)[0]!);} return result;
}
