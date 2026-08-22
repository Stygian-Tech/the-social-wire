import { Avatar } from "@/components/shared/Avatar";
import { outboundLinkProps } from "@/lib/outboundLinks";
import type { WireTalkedAboutPerson } from "@/lib/wireEditionClient";
import { WireHorizontalRail } from "./WireHorizontalRail";

function profileUrl(person: WireTalkedAboutPerson): string {
  const profile = person.handle.trim().replace(/^@/, "") || person.did;
  return `https://bsky.app/profile/${encodeURIComponent(profile)}`;
}

export function WireTalkedAboutPeople({
  people,
}: {
  people: WireTalkedAboutPerson[];
}) {
  if (people.length === 0) return null;
  return (
    <WireHorizontalRail
      id="talked-about-people"
      eyebrow="In The Conversation"
      title="People in the Story"
    >
      {people.map((person) => (
        <a
          key={person.did}
          href={profileUrl(person)}
          {...outboundLinkProps}
          className="flex w-[min(72vw,18rem)] shrink-0 snap-start gap-3 rounded-2xl border border-border/70 bg-card/88 p-4 text-left shadow-sm transition-[border-color,background-color,box-shadow] hover:border-[var(--purple-border)] hover:bg-muted/35 hover:[box-shadow:var(--purple-glow-hover)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:w-72 dark:border-border/55 dark:bg-card/82"
        >
          <Avatar
            src={person.avatarUrl}
            alt={person.displayName || person.handle}
            size={48}
            className="size-12 shrink-0"
          />
          <span className="min-w-0">
            <span className="block truncate text-sm font-bold text-foreground">
              {person.displayName.trim() || person.handle}
            </span>
            <span className="block truncate text-xs text-muted-foreground">
              {person.handle.startsWith("@") ? person.handle : `@${person.handle}`}
            </span>
            {person.description?.trim() ? (
              <span className="mt-2 line-clamp-2 block text-xs leading-4 text-muted-foreground">
                {person.description}
              </span>
            ) : null}
          </span>
        </a>
      ))}
    </WireHorizontalRail>
  );
}
