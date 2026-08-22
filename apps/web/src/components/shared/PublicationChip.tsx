"use client";

import { Avatar } from "@/components/shared/Avatar";
import { outboundLinkProps } from "@/lib/outboundLinks";
import { cn } from "@/lib/utils";

export type PublicationChipModel = {
  name: string;
  faviconUrl?: string;
  homepageUrl?: string;
};

export function PublicationChip({
  publication,
  className,
  nameClassName,
  overlay = false,
}: {
  publication: PublicationChipModel;
  className?: string;
  nameClassName?: string;
  overlay?: boolean;
}) {
  const content = (
    <>
      <Avatar
        src={publication.faviconUrl}
        alt=""
        size={16}
        className="size-4 shrink-0"
      />
      <span className={cn("truncate", nameClassName)}>{publication.name}</span>
    </>
  );
  const classes = cn(
    "inline-flex max-w-full min-w-0 items-center gap-1.5 rounded-full border border-[var(--purple-border)] px-2.5 py-1 text-xs font-semibold text-[var(--purple-foreground)]",
    overlay
      ? "bg-background/92 shadow-sm backdrop-blur-sm"
      : "bg-primary/10",
    className,
  );
  return publication.homepageUrl ? (
    <a
      href={publication.homepageUrl}
      {...outboundLinkProps}
      className={cn(classes, "transition-colors hover:bg-accent/70")}
      title={`Open ${publication.name}`}
    >
      {content}
    </a>
  ) : (
    <span className={classes}>{content}</span>
  );
}
