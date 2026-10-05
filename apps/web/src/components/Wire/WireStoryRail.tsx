import type { EntryListItem } from "@/lib/atprotoClient";
import { WireHorizontalRail } from "./WireHorizontalRail";
import { WireStoryCard } from "./WireStoryCard";

export function WireStoryRail({
  id,
  title,
  stories,
  eyebrow,
  onNearEnd,
  behindSidebar = false,
  onSelect,
}: {
  id: string;
  title: string;
  stories: EntryListItem[];
  eyebrow?: string;
  onNearEnd?: () => void;
  behindSidebar?: boolean;
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  if (stories.length === 0) return null;
  return (
    <WireHorizontalRail id={id} title={title} eyebrow={eyebrow} onNearEnd={onNearEnd} behindSidebar={behindSidebar}>
      {stories.map((story) => (
        <div
          key={story.entryId}
          className="w-[min(78vw,20rem)] shrink-0 snap-start sm:w-80"
        >
          <WireStoryCard story={story} onSelect={onSelect} />
        </div>
      ))}
    </WireHorizontalRail>
  );
}
