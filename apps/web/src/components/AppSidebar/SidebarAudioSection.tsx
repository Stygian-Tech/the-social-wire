"use client";

import { useId, useRef, useState } from "react";
import { Popover } from "@base-ui/react/popover";
import { Headphones, SlidersHorizontal } from "lucide-react";
import { WireBetaBadge } from "@/components/Wire/WireBetaBadge";
import { SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuItem, SidebarMenuButton } from "@/components/ui/sidebar";
import { useOptionalPodcastPlayer } from "@/components/Podcasts/PodcastPlayerProvider";
import { PodcastPlaybackWaveform } from "@/components/Podcasts/PodcastPlaybackWaveform";
import { PodcastSidebarMiniPlayer } from "@/components/Podcasts/PodcastSidebarMiniPlayer";

export function SidebarAudioSection({ enabled, active, onSelect }: { enabled: boolean; active: boolean; onSelect: () => void }) {
  const player = useOptionalPodcastPlayer();
  const [open, setOpen] = useState(false);
  const anchor = useRef<HTMLLIElement | null>(null);
  const triggerId = useId();
  if (!enabled) return null;
  const tab = <SidebarMenuButton type="button" role="tab" aria-label="Podcasts, Beta" aria-selected={active} isActive={active} onClick={onSelect} className={player?.episode ? "pr-11 pointer-coarse:min-h-11" : "pointer-coarse:min-h-11"}>
    {player?.playing ? <PodcastPlaybackWaveform player={player} /> : <Headphones />}
    <span>Podcasts</span><WireBetaBadge className="ml-auto" />
  </SidebarMenuButton>;
  return <SidebarGroup className="pb-1 pt-1">
    <SidebarGroupLabel>Audio</SidebarGroupLabel>
    <SidebarMenu role="tablist" aria-label="Audio">
      <SidebarMenuItem ref={anchor}>
        {player?.episode ? <Popover.Root open={open} onOpenChange={setOpen}>
          <Popover.Trigger id={triggerId} render={tab} openOnHover delay={100} closeDelay={200} onFocus={() => setOpen(true)} />
          <Popover.Trigger aria-label="Podcast Playback Controls" className="absolute inset-y-0 right-0 flex min-h-8 min-w-8 items-center justify-center rounded-md hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring pointer-coarse:min-h-11 pointer-coarse:min-w-11">
            <SlidersHorizontal aria-hidden="true" className="size-3.5" />
          </Popover.Trigger>
          <PodcastSidebarMiniPlayer player={player} anchor={anchor} />
        </Popover.Root> : tab}
      </SidebarMenuItem>
    </SidebarMenu>
  </SidebarGroup>;
}
