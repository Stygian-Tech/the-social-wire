"use client";

import { useCallback, useEffect, useState } from "react";
import { use } from "react";
import { ChevronLeft } from "lucide-react";
import { EntryList } from "@/components/EntryList/EntryList";
import { EntryDetail } from "@/components/EntryDetail/EntryDetail";
import { Button } from "@/components/ui/button";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { readRoutePubIdFromSegments } from "@/lib/atprotoClient";
import { cn } from "@/lib/utils";

interface Props {
  params: Promise<{ pubId: string[] }>;
}

export default function PubPage({ params }: Props) {
  const { pubId: pubSegments } = use(params);
  const pubId = readRoutePubIdFromSegments(pubSegments);
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);
  const { markEntryRead, isEntryRead, isHiddenFolderContext } = useReadRoute();

  const handleSelectEntry = useCallback(
    (entryId: string) => {
      setSelectedEntryId(entryId);
      markEntryRead(entryId);
    },
    [markEntryRead]
  );

  useEffect(() => {
    setSelectedEntryId(null);
  }, [pubId]);

  return (
    <div className="flex h-full min-h-0 flex-1 flex-col overflow-hidden md:flex-row md:items-stretch">
      {/* Article list — desktop: beside publications sidebar; mobile: full width until an entry opens */}
      <aside
        className={cn(
          "flex min-h-0 min-w-0 flex-col overflow-hidden border-r bg-muted/20",
          "w-full flex-1 md:h-full md:w-72 md:shrink-0 md:flex-none",
          selectedEntryId && "hidden md:flex"
        )}
      >
        <div className="shrink-0 border-b px-3 py-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
            Articles
          </p>
        </div>
        <div className="min-h-0 flex-1 overflow-hidden">
          <EntryList
            pubId={pubId}
            selectedEntryId={selectedEntryId}
            onSelectEntry={handleSelectEntry}
            isEntryRead={isEntryRead}
            readIndicatorsEnabled={!isHiddenFolderContext}
          />
        </div>
      </aside>

      {/* Entry detail */}
      <div
        className={cn(
          "flex min-h-0 min-w-0 flex-1 flex-col overflow-y-auto overflow-x-hidden md:h-full",
          !selectedEntryId && "hidden md:flex"
        )}
      >
        {selectedEntryId ? (
          <>
            <div className="bg-background sticky top-0 z-10 flex shrink-0 items-center gap-2 border-b px-1 md:hidden">
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                className="shrink-0"
                aria-label="Back to articles"
                onClick={() => setSelectedEntryId(null)}
              >
                <ChevronLeft className="size-4" />
              </Button>
              <span className="text-sm font-medium text-muted-foreground">
                Articles
              </span>
            </div>
            <div className="flex min-h-0 flex-1 flex-col">
              <EntryDetail entryId={selectedEntryId} />
            </div>
          </>
        ) : (
          <div className="hidden flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground md:flex">
            Select an Article from the List
          </div>
        )}
      </div>
    </div>
  );
}
