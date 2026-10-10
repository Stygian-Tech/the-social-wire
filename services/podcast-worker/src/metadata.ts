import { publicUrl } from "./publicFetch";
import type { PodcastChapter, PodcastPerson } from "./types";
export const object=(v:unknown):Record<string,unknown>=>v&&typeof v==="object"?v as Record<string,unknown>:{};
export const safeUrl=(v:unknown):string|undefined=>{if(typeof v!=="string")return;try{return publicUrl(v).href;}catch{return;}};
export function chapters(value:unknown,duration?:number):PodcastChapter[] {
  const list=Array.isArray(value)?value:object(value).chapters;
  if(!Array.isArray(list))return [];
  return list.slice(0,1000).flatMap(v=>{const row=object(v);const start=row.startSeconds??row.startTime??row.start;
    if(row.toc===false||typeof start!=="number"||!Number.isFinite(start)||start<0||(duration!==undefined&&start>=duration))return [];
    return [{startSeconds:start,title:typeof row.title==="string"?row.title.slice(0,512):"Chapter",artworkUrl:safeUrl(row.artworkUrl??row.img??row.image),url:safeUrl(row.url??row.href)}];
  }).sort((a,b)=>a.startSeconds-b.startSeconds);
}
export function people(value:unknown):PodcastPerson[] {
  if(!Array.isArray(value))return [];
  return value.slice(0,100).flatMap(v=>{const row=object(v),attributes=object(row.$);const name=row.name??row._;const role=row.role??attributes.role??"host";
    if(typeof name!=="string"||!name.trim()||typeof role!=="string"||!["host","co-host","cohost"].includes(role.toLowerCase()))return [];
    return [{name:name.trim().slice(0,128),role,imageUrl:safeUrl(row.imageUrl??row.img??attributes.img),url:safeUrl(row.url??row.href??attributes.href)}];
  });
}
export function bridgeEnabled():boolean {return process.env.PODCAST_BRIDGE_ENABLED==="true";}
