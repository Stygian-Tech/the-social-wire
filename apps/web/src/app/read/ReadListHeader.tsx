"use client";
import { RefreshCw } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import {
  useStandardReaderList,
  useStandardReaderLists,
} from "@/hooks/useStandardReaderLists";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
export function ReadListHeader({ uri }: { uri: string }) {
  const list = useStandardReaderList(uri);
  const lists = useStandardReaderLists();
  const { session } = useAuth();
  const client = useQueryClient();
  return (
    <FeedHeader title={list.data?.name ?? "List"}>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label="Refresh List"
        disabled={lists.refreshing}
        onClick={() => {
          void lists
            .refresh()
            .then(() =>
              Promise.all([
                list.refetch(),
                client.invalidateQueries({
                  queryKey: [
                    "aggregateEntries",
                    session?.did ?? "",
                    "list",
                    uri,
                  ],
                }),
              ]),
            )
            .catch(() => undefined);
        }}
      >
        <RefreshCw aria-hidden="true" className="size-3.5" />
      </Button>
    </FeedHeader>
  );
}
