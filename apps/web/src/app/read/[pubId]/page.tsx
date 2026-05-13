"use client";

import { useState } from "react";
import { use } from "react";
import { EntryList } from "@/components/EntryList/EntryList";
import { EntryDetail } from "@/components/EntryDetail/EntryDetail";

interface Props {
  params: Promise<{ pubId: string }>;
}

export default function PubPage({ params }: Props) {
  const { pubId } = use(params);
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);

  return (
    <div className="flex flex-1 overflow-hidden">
      {/* Entry list — fixed width, full height, scrollable */}
      <div className="w-72 shrink-0 border-r overflow-hidden flex flex-col">
        <EntryList
          pubId={pubId}
          selectedEntryId={selectedEntryId}
          onSelectEntry={setSelectedEntryId}
        />
      </div>

      {/* Entry detail — flex fill, scrollable */}
      <div className="flex flex-1 overflow-y-auto">
        {selectedEntryId ? (
          <EntryDetail entryId={selectedEntryId} />
        ) : (
          <div className="flex flex-1 items-center justify-center text-sm text-muted-foreground p-8 text-center">
            Select an entry to read
          </div>
        )}
      </div>
    </div>
  );
}
