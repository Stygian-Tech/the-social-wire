"use client";

import { PublicationChip } from "@/components/shared/PublicationChip";
import { useSavedLinkPublication } from "@/hooks/useSavedLinkPublication";
import type { MergedLatrSave } from "@/lib/pdsClient";

type Props = {
  row: MergedLatrSave;
  className?: string;
  /** Semi-opaque styling for overlay on thumbnail images. */
  overlay?: boolean;
};

export function SavedLinkPublicationChip({ row, className, overlay }: Props) {
  const publication = useSavedLinkPublication(row);
  if (!publication) return null;

  return (
    <PublicationChip
      publication={publication}
      className={className}
      overlay={overlay}
    />
  );
}
