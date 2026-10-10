"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Popover } from "@base-ui/react/popover";
import { Headphones } from "lucide-react";
import { WireBetaBadge } from "@/components/Wire/WireBetaBadge";
import { SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuItem, SidebarMenuButton } from "@/components/ui/sidebar";
import { useOptionalPodcastPlayer } from "@/components/Podcasts/PodcastPlayerProvider";
import { PodcastPlaybackWaveform } from "@/components/Podcasts/PodcastPlaybackWaveform";
import { PodcastSidebarMiniPlayer } from "@/components/Podcasts/PodcastSidebarMiniPlayer";
import { useClientHydrated } from "@/hooks/useClientHydrated";

export function SidebarAudioSection({ enabled, active, onSelect }: { enabled: boolean; active: boolean; onSelect: () => void }) {
  const restoredPlayer = useOptionalPodcastPlayer();
  const hydrated = useClientHydrated();
  // Cached playback can restore before this sidebar hydrates. Keep its first
  // render identical to the server, then attach the episode's preview controls.
  const player = hydrated ? restoredPlayer : null;
  const [open, setOpen] = useState(false);
  const anchor = useRef<HTMLLIElement | null>(null);
  const triggerId = useId();
  const instructionsId = useId();
  const holdTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const press = useRef<{ id: number; x: number; y: number } | null>(null);
  const touchFocus = useRef(false);
  const suppressClick = useRef(false);
  const cancelHold = () => {
    if (holdTimer.current !== null) clearTimeout(holdTimer.current);
    holdTimer.current = null;
    press.current = null;
  };
  useEffect(() => cancelHold, [enabled, player?.episode?.id]);
  if (!enabled) return null;
  const tab = <SidebarMenuButton type="button" role="tab" aria-label="Podcasts, Beta" aria-describedby={player?.episode ? instructionsId : undefined} aria-selected={active} isActive={active}
    onClick={event => {
      if (suppressClick.current) { event.preventDefault(); suppressClick.current = false; return; }
      cancelHold(); setOpen(false); onSelect();
    }}
    onPointerDown={event => {
      cancelHold(); suppressClick.current = false;
      touchFocus.current = event.pointerType === "touch";
      if (!player?.episode || !touchFocus.current) return;
      press.current = { id: event.pointerId, x: event.clientX, y: event.clientY };
      holdTimer.current = setTimeout(() => { holdTimer.current = null; suppressClick.current = true; setOpen(true); }, 500);
    }}
    onPointerMove={event => {
      const current = press.current;
      if (!current || event.pointerId !== current.id || Math.hypot(event.clientX - current.x, event.clientY - current.y) <= 10) return;
      cancelHold(); suppressClick.current = true; setOpen(false);
    }}
    onPointerUp={cancelHold}
    onPointerCancel={() => { cancelHold(); suppressClick.current = true; }}
    onBlur={() => { touchFocus.current = false; cancelHold(); }}
    onContextMenu={event => { if (touchFocus.current) event.preventDefault(); }}
    onKeyDown={() => { touchFocus.current = false; }}
    className="select-none pointer-coarse:min-h-11">
    <Headphones /><span>Podcasts</span>
    {player?.playing ? <PodcastPlaybackWaveform player={player} /> : null}
    <WireBetaBadge className="ml-auto" />
  </SidebarMenuButton>;
  return <SidebarGroup className="pb-1 pt-1">
    <SidebarGroupLabel>Audio</SidebarGroupLabel>
    <SidebarMenu role="tablist" aria-label="Audio">
      <SidebarMenuItem ref={anchor}>
        {player?.episode ? <Popover.Root triggerId={triggerId} open={open} onOpenChange={(nextOpen, details) => {
          // Selecting Podcasts navigates; only hover, focus, or a touch hold previews controls.
          if (details.reason === "trigger-press") { details.cancel(); return; }
          setOpen(nextOpen);
        }}>
          <Popover.Trigger id={triggerId} render={tab} openOnHover delay={100} closeDelay={200} onFocus={() => { if (!touchFocus.current) setOpen(true); }} />
          <span id={instructionsId} className="sr-only">Hover, Focus, or Touch and Hold for Playback Controls</span>
          <PodcastSidebarMiniPlayer player={player} anchor={anchor} />
        </Popover.Root> : tab}
      </SidebarMenuItem>
    </SidebarMenu>
  </SidebarGroup>;
}
