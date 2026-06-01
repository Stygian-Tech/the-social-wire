"use client";

import { useState } from "react";
import {
  QueryClient,
  type Query,
  type InfiniteData,
} from "@tanstack/react-query";
import { PersistQueryClientProvider } from "@tanstack/react-query-persist-client";
import { createSyncStoragePersister } from "@tanstack/query-sync-storage-persister";
import { AuthProvider } from "@/hooks/useAuth";
import { LexiconMigrationRunner } from "@/hooks/useLexiconMigration";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { shouldPersistSidebarProjection } from "@/lib/sidebarProjectionPersist";

/** localStorage key for dehydrated React Query cache (discovery + bounded entry lists). */
const QUERY_PERSIST_KEY = "the-social-wire.react-query.v1";

/** Drop persisted payload older than this (ms). */
const QUERY_PERSIST_MAX_AGE_MS = 1000 * 60 * 60 * 24 * 7; // 7 days

type EntryListPage = { entries: unknown[]; cursor?: string };

function shouldPersistDiscoveryQuery(query: Query): boolean {
  const key = query.queryKey;
  return Array.isArray(key) && key[0] === "discovery";
}

/** Avoid large localStorage writes: persist `["entries", did]` only when small. */
function shouldPersistEntriesQuery(query: Query): boolean {
  const key = query.queryKey;
  if (!Array.isArray(key) || key[0] !== "entries") return false;
  const data = query.state.data as InfiniteData<EntryListPage> | undefined;
  if (!data?.pages?.length) return false;
  const pageCount = data.pages.length;
  const totalEntries = data.pages.reduce(
    (n, p) => n + (p.entries?.length ?? 0),
    0
  );
  return pageCount <= 3 && totalEntries <= 120;
}

function shouldPersistSidebarProjectionQuery(query: Query): boolean {
  const key = query.queryKey;
  if (!Array.isArray(key) || key[0] !== "publicationSidebarProjection") return false;
  const data = query.state.data as PublicationSidebarProjection | undefined;
  return shouldPersistSidebarProjection(data);
}

function shouldDehydrateQuery(query: Query): boolean {
  return (
    shouldPersistDiscoveryQuery(query) ||
    shouldPersistEntriesQuery(query) ||
    shouldPersistSidebarProjectionQuery(query)
  );
}

function getBrowserStorage(): Storage | undefined {
  if (typeof window === "undefined") return undefined;

  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
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
    createSyncStoragePersister({
      storage: getBrowserStorage(),
      key: QUERY_PERSIST_KEY,
      /** Discovery + entry streams: throttle persist writes. */
      throttleTime: 2000,
    })
  );

  return (
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
  );
}
