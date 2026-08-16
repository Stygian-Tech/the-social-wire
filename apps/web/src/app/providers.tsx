"use client";

import { useState } from "react";
import {
  QueryClient,
  type Query,
  type InfiniteData,
} from "@tanstack/react-query";
import { PersistQueryClientProvider } from "@tanstack/react-query-persist-client";
import { AuthProvider } from "@/hooks/useAuth";
import { AppearanceProvider } from "@/hooks/useAppearance";
import { LexiconMigrationRunner } from "@/hooks/useLexiconMigration";
import { createIndexedDbQueryPersister } from "@/lib/indexedDbQueryPersister";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { shouldPersistSidebarProjection } from "@/lib/sidebarProjectionPersist";

/** IndexedDB key for dehydrated React Query cache (sidebar + bounded entry lists). */
const QUERY_PERSIST_KEY = "the-social-wire.react-query.v2";

/** Drop persisted payload older than this (ms). */
const QUERY_PERSIST_MAX_AGE_MS = 1000 * 60 * 60 * 24 * 7; // 7 days

type EntryListPage = { entries: unknown[]; cursor?: string };

/** Persist successful viewer-scoped feed pages only when they remain bounded. */
function shouldPersistEntriesQuery(query: Query): boolean {
  const key = query.queryKey;
  if (
    !Array.isArray(key) ||
    (key[0] !== "entries" && key[0] !== "aggregateEntries") ||
    typeof key[1] !== "string" ||
    key[1].length === 0 ||
    query.state.status !== "success"
  ) {
    return false;
  }
  const data = query.state.data as InfiniteData<EntryListPage> | undefined;
  if (!data?.pages?.length) return false;
  const pageCount = data.pages.length;
  const totalEntries = data.pages.reduce(
    (n, p) => n + (p.entries?.length ?? 0),
    0
  );
  return pageCount <= 3 && totalEntries <= 150;
}

function shouldPersistSidebarProjectionQuery(query: Query): boolean {
  const key = query.queryKey;
  if (!Array.isArray(key) || key[0] !== "publicationSidebarProjection") return false;
  const data = query.state.data as PublicationSidebarProjection | undefined;
  return shouldPersistSidebarProjection(data);
}

function shouldDehydrateQuery(query: Query): boolean {
  return (
    shouldPersistEntriesQuery(query) ||
    shouldPersistSidebarProjectionQuery(query)
  );
}

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000,
            retry: 1,
          },
        },
      })
  );

  const [persister] = useState(() =>
    createIndexedDbQueryPersister({
      dbName: "the-social-wire-cache",
      storeName: "react-query",
      key: QUERY_PERSIST_KEY,
      /** Discovery + entry streams: throttle persist writes. */
      throttleTime: 2000,
    })
  );

  return (
    <AppearanceProvider>
      <PersistQueryClientProvider
        client={queryClient}
        persistOptions={{
          persister,
          maxAge: QUERY_PERSIST_MAX_AGE_MS,
          dehydrateOptions: {
            shouldDehydrateQuery,
          },
        }}
      >
        <AuthProvider>
          <LexiconMigrationRunner />
          {children}
        </AuthProvider>
      </PersistQueryClientProvider>
    </AppearanceProvider>
  );
}
