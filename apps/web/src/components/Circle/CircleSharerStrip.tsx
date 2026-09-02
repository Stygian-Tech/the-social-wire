import { Avatar } from "@/components/shared/Avatar";
import type { CircleSharer } from "@/lib/circleFeedClient";
import { outboundLinkProps } from "@/lib/outboundLinks";
import { cn } from "@/lib/utils";

const MAX_VISIBLE_SHARERS = 5;

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

export function CircleSharerStrip({
  sharers,
  totalCount = sharers.length,
  compact = false,
}: {
  sharers: CircleSharer[];
  totalCount?: number;
  compact?: boolean;
}) {
  const visible = sharers.slice(0, MAX_VISIBLE_SHARERS);
  const overflow = Math.max(0, totalCount - visible.length);
  const avatarSize = compact ? 22 : 24;
  if (visible.length === 0) return null;

  return (
    <div
      aria-label="Shared In Your Circle"
      className={cn(
        "mt-2 flex min-w-0 items-center text-[11px] text-muted-foreground",
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
            aria-label={`Open ${name}'s public share context${sharer.relationship === "one_hop" ? ", one hop away" : ""}`}
            title={name}
            className="relative -ml-2 inline-flex rounded-full first:ml-0 hover:z-10 focus-visible:z-10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--purple-border)] focus-visible:ring-offset-2 focus-visible:ring-offset-background"
            onClick={(event) => event.stopPropagation()}
            onKeyDown={(event) => event.stopPropagation()}
          >
            <Avatar
              src={sharer.identity.avatarUrl}
              alt={name}
              size={avatarSize}
              className="shrink-0 border-2 border-background shadow-sm"
            />
            {sharer.relationship === "one_hop" ? (
              <span
                aria-hidden="true"
                className="absolute -bottom-1 -right-1 z-20 inline-flex min-w-4 items-center justify-center rounded-full border border-background bg-muted px-0.5 text-[8px] font-bold leading-3 text-foreground shadow-sm"
              >
                +1
              </span>
            ) : null}
          </a>
        );
      })}
      {overflow > 0 ? (
        <span
          aria-label={`${overflow} more accounts`}
          className="ml-1.5 inline-flex min-h-5 items-center rounded-full bg-muted px-2 font-semibold text-foreground"
        >
          +{overflow}
        </span>
      ) : null}
    </div>
  );
}
