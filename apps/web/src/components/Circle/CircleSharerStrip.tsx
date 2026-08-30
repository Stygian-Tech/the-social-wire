import { Avatar } from "@/components/shared/Avatar";
import type { CircleSharer } from "@/lib/circleFeedClient";
import { outboundLinkProps } from "@/lib/outboundLinks";
import { cn } from "@/lib/utils";

const MAX_VISIBLE_SHARERS = 3;

export function publicCircleShareURL(sharer: CircleSharer): string {
  const match = sharer.sourceUri.match(
    /^at:\/\/([^/]+)\/app\.bsky\.feed\.post\/([^/?#]+)$/,
  );
  if (match) {
    return `https://bsky.app/profile/${encodeURIComponent(match[1]!)}/post/${encodeURIComponent(match[2]!)}`;
  }
  if (sharer.sourceUri.startsWith("at://")) {
    return `https://pdsls.dev/${sharer.sourceUri}`;
  }
  const profile = sharer.identity.handle.trim() || sharer.identity.did;
  return `https://bsky.app/profile/${encodeURIComponent(profile)}`;
}

function relationshipLabel(sharer: CircleSharer): string {
  return sharer.relationship === "direct" ? "Following" : "One Hop";
}

export function CircleSharerStrip({
  sharers,
  compact = false,
}: {
  sharers: CircleSharer[];
  compact?: boolean;
}) {
  const visible = sharers.slice(0, MAX_VISIBLE_SHARERS);
  const overflow = Math.max(0, sharers.length - visible.length);
  if (visible.length === 0) return null;

  return (
    <div
      aria-label="Shared In Your Circle"
      className={cn(
        "mt-2 flex min-w-0 flex-wrap items-center gap-1.5 text-[11px] text-muted-foreground",
        compact && "mt-1.5",
      )}
    >
      {visible.map((sharer) => {
        const name =
          sharer.identity.displayName?.trim() || sharer.identity.handle;
        return (
          <a
            key={`${sharer.identity.did}:${sharer.sourceUri}`}
            href={publicCircleShareURL(sharer)}
            {...outboundLinkProps}
            data-source-uri={sharer.sourceUri}
            aria-label={`Open ${name}'s public share context`}
            className="inline-flex max-w-40 items-center gap-1 rounded-full border border-border/70 bg-background/80 py-0.5 pl-0.5 pr-2 hover:border-[var(--purple-border)] hover:text-foreground"
            onClick={(event) => event.stopPropagation()}
            onKeyDown={(event) => event.stopPropagation()}
          >
            <Avatar
              src={sharer.identity.avatarUrl}
              alt={name}
              size={20}
              className="shrink-0"
            />
            <span className="truncate">{name}</span>
            <span className="shrink-0 text-[9px] uppercase tracking-wide text-muted-foreground/80">
              {relationshipLabel(sharer)}
            </span>
          </a>
        );
      })}
      {overflow > 0 ? (
        <span className="inline-flex min-h-5 items-center rounded-full bg-muted px-2 font-semibold text-foreground">
          +{overflow}
        </span>
      ) : null}
    </div>
  );
}
