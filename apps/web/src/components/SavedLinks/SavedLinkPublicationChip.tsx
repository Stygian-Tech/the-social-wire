"use client";

import { Avatar } from "@/components/shared/Avatar";
import { useSavedLinkPublication } from "@/hooks/useSavedLinkPublication";
import type { MergedLatrSave } from "@/lib/pdsClient";
import { cn } from "@/lib/utils";

type Props = {
  row: MergedLatrSave;
  className?: string;
  /** Semi-opaque styling for overlay on thumbnail images. */
  overlay?: boolean;
};

export function SavedLinkPublicationChip({ row, className, overlay }: Props) {
  const publication = useSavedLinkPublication(row);
  if (!publication) return null;

  const chip = (
    <>
      <Avatar
        src={publication.faviconUrl}
        alt={publication.name}
        size={16}
        className="size-4 shrink-0"
      />
      <span className="truncate">{publication.name}</span>
    </>
  );

  const chipClassName = cn(
    "inline-flex max-w-full min-w-0 items-center gap-1.5 rounded-full border border-border px-2.5 py-1 text-xs font-medium text-foreground",
    overlay
      ? "border-border/60 bg-background/90 shadow-sm backdrop-blur-sm"
      : "bg-muted/40",
    className
  );

  if (publication.homepageUrl) {
    return (
      <a
        href={publication.homepageUrl}
        target="_blank"
        rel="noopener noreferrer"
        className={cn(chipClassName, "transition-colors hover:bg-muted/70")}
        title={`Open ${publication.name}`}
      >
        {chip}
      </a>
    );
  }

  return <div className={chipClassName}>{chip}</div>;
}
