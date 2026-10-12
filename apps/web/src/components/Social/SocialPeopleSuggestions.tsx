"use client";

import { forwardRef, useEffect, useImperativeHandle, useState } from "react";
import { moderateProfile, type AppBskyActorDefs } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialExplore } from "@/hooks/useSocialDiscovery";
import { Avatar } from "@/components/shared/Avatar";
import { socialHttpsUrl } from "./socialUrls";

export type PeopleSuggestionControl = { keyDown: (key: string) => boolean };
export const SocialPeopleSuggestions = forwardRef<PeopleSuggestionControl, { query: string; id: string; onSelect: (actor: AppBskyActorDefs.ProfileView) => void; onDismiss: () => void; below?: boolean; onActiveChange: (id: string | undefined) => void }>(function SocialPeopleSuggestions({ query, id, onSelect, onDismiss, below, onActiveChange }, ref) {
  const { session } = useAuth();
  const catalog = useBlueskySocialCatalog();
  const available = catalog.data?.moderation;
  const moderation = !catalog.isError && available?.userDid === session?.did ? available : undefined;
  const [debounced, setDebounced] = useState<string>();
  const [active, setActive] = useState(0);
  useEffect(() => { const timer = setTimeout(() => setDebounced(query), 200); return () => clearTimeout(timer); }, [query]);
  const results = useSocialExplore(debounced ?? "", "people", debounced !== undefined && debounced === query ? moderation : undefined);
  const actors = moderation && debounced === query ? (results.data?.pages[0]?.actors ?? []).filter(actor => {
    const decision = moderateProfile(actor, moderation).ui("profileList");
    const name = moderateProfile(actor, moderation).ui("displayName");
    return !decision.filter && !decision.blur && !decision.noOverride && !name.filter && !name.blur && !name.noOverride;
  }).slice(0, 6) : [];
  const selected = Math.min(active, Math.max(0, actors.length - 1));
  const activeId = actors[selected] ? `${id}-${selected}` : undefined;
  useEffect(() => { onActiveChange(activeId); }, [activeId, onActiveChange]);
  useImperativeHandle(ref, () => ({ keyDown(key) {
    if (key === "Escape") { onDismiss(); return true; }
    if (!actors.length) return false;
    if (key === "ArrowDown" || key === "ArrowUp") { setActive((selected + (key === "ArrowDown" ? 1 : actors.length - 1)) % actors.length); return true; }
    if (key === "Enter" || key === "Tab") { onSelect(actors[selected]); return true; }
    return false;
  } }));
  return <div className={`absolute left-0 z-50 max-h-64 w-full max-w-full overflow-y-auto rounded-xl border bg-popover p-1 text-popover-foreground shadow-lg ${below ? "top-full mt-1" : "bottom-full mb-1"}`}>
    <div id={id} role="listbox" aria-label="People Suggestions">
      {actors.map((actor, index) => <button type="button" role="option" id={`${id}-${index}`} aria-label={`${actor.displayName || actor.handle} @${actor.handle}`} aria-selected={index === selected} key={actor.did} onPointerDown={event => event.preventDefault()} onClick={() => onSelect(actor)} className={`flex w-full min-w-0 items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm ${index === selected ? "bg-accent" : "hover:bg-accent"}`}>
        <Avatar src={moderation && !["blur", "filter", "noOverride"].some(flag => moderateProfile(actor, moderation).ui("avatar")[flag as "blur" | "filter" | "noOverride"]) ? socialHttpsUrl(actor.avatar) : undefined} alt="" size={28} />
        <span className="min-w-0"><span className="block truncate font-medium">{actor.displayName || actor.handle}</span><span className="block truncate text-xs text-muted-foreground">@{actor.handle}</span></span>
      </button>)}
    </div>
    {!actors.length ? <p role="status" className="p-2 text-xs text-muted-foreground">{catalog.isError || results.isError ? "People Could Not Be Loaded" : debounced !== query || !moderation || results.isPending ? "Loading People…" : "No Matching People"}</p> : null}
  </div>;
});
