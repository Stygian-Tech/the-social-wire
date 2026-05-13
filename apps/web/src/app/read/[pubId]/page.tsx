"use client";

import { useCallback, useState } from "react";
import { use } from "react";
import { EntryList } from "@/components/EntryList/EntryList";
import { EntryDetail } from "@/components/EntryDetail/EntryDetail";
import { useReadRoute } from "@/contexts/ReadRouteContext";

interface Props {
  params: Promise<{ pubId: string }>;
}

export default function PubPage({ params }: Props) {
  const { pubId } = use(params);
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);
  const { markEntryRead, isEntryRead, isHiddenFolderContext } = useReadRoute();

  const handleSelectEntry = useCallback(
    (entryId: string) => {
      setSelectedEntryId(entryId);
      markEntryRead(entryId);
    },
    [markEntryRead]
  );

  return (
    <div className="flex flex-1 min-h-0 overflow-hidden">
      {/* Article list — second column after publications sidebar */}
      <aside className="flex w-72 shrink-0 flex-col border-r bg-muted/20 min-h-0">
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
      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto">
        {selectedEntryId ? (
          <EntryDetail entryId={selectedEntryId} />
        ) : (
          <div className="flex flex-1 items-center justify-center p-8 text-center text-sm text-muted-foreground">
            Select an article from the list
          </div>
        )}
      </div>
    </div>
  );
}
