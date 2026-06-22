"use client";

import type { ReactNode } from "react";
import { ArticleSocialToolbar } from "@/components/EntryDetail/ArticleSocialToolbar";
import { Skeleton } from "@/components/ui/skeleton";
import { useSavedLinkSocialEntry } from "@/hooks/useSavedLinkSocialEntry";
import type { MergedLatrSave } from "@/lib/pdsClient";
import { cn } from "@/lib/utils";

type Props = {
  row: MergedLatrSave;
  className?: string;
  extraActions?: ReactNode;
};

export function SavedLinkSocialToolbar({ row, className, extraActions }: Props) {
  const { entry, isLoading } = useSavedLinkSocialEntry(row);

  if (isLoading) {
    return (
      <div className={cn("mb-2", className)}>
        <Skeleton className="h-9 w-full max-w-md rounded-md" />
      </div>
    );
  }

  return (
    <ArticleSocialToolbar
      entry={entry}
      showReadLaterSave={false}
      extraActions={extraActions}
      className={className}
    />
  );
}
