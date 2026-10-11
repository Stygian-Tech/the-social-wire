import { Agent } from "@atproto/api";
import { socialHttpsUrl } from "@/components/Social/socialUrls";

export type BrandAccountPublicProfile = { did: string; handle: string; displayName?: string; avatar?: string };

/** Profile labels are public metadata; never attach a linked or personal OAuth session. */
export async function getBrandAccountPublicProfile(did: string, appView: string, signal?: AbortSignal): Promise<BrandAccountPublicProfile> {
  const { data } = await new Agent(appView).app.bsky.actor.getProfile({ actor: did }, { signal });
  if (data.did !== did || typeof data.handle !== "string" || !data.handle.trim()) throw new Error("Brand Profile Metadata Is Unavailable.");
  return { did, handle: data.handle, displayName: typeof data.displayName === "string" ? data.displayName.trim() || undefined : undefined, avatar: socialHttpsUrl(data.avatar) };
}
