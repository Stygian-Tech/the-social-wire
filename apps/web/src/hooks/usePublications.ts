"use client";

import { useMemo } from "react";
import {
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { usePDSClient } from "./usePDSClient";
import { useAuth } from "./useAuth";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import {
  discoveredPublicationFromAtUri,
  normalizeAtRepoParam,
  parseAtUri,
  PUBLICATION_RECORD_COLLECTIONS,
  publicationRepoDid,
  type DiscoveredPublication,
} from "@/lib/atprotoClient";
import {
  COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
  COLLECTION_STANDARD_SITE_SUBSCRIPTION,
  type PDSClient,
  type RepoRecord,
  rkeyFromURI,
  type SkyreaderFeedSubscriptionRecord,
} from "@/lib/pdsClient";
import {
  addPublicationSubscriptionLookupKeys,
  publicationIdsMatch,
  publicationSubscriptionMatchKeys,
  standardSiteSubscriptionTargetFromDiscovery,
} from "@/lib/publicationSubscriptionMatch";
import {
  isRssPublicationId,
  normalizeRssFeedUrlInput,
  normalizedFeedUrlFromRssPublicationId,
  rssPublicationIdFromNormalizedFeedUrl,
} from "@/lib/rssFeedCore";
import {
  fetchEntriesInfinitePage,
  ENTRIES_QUERY_KEY,
  type EntriesPage,
} from "@/hooks/useEntries";
import {
  enrollAuthorsInAppView,
} from "@/lib/thinAppViewClient";
import {
  applyPublicationFolderMoveToProjection,
  reconcilePublicationPrefAfterWrite,
} from "@/lib/optimisticPublicationFolderMove";
import { applySidebarPriorityEvent } from "@/lib/bootstrapStreamState";
import {
  refreshPublicationSidebar,
  type PublicationSidebarProjection,
  type ResolveAddPublicationPayload,
} from "@/lib/publicationProjectionClient";
import {
  removePublicationFromEntryCaches,
  removePublicationFromSidebarProjection,
} from "@/lib/publicationUnsubscribeCache";

export type { DiscoveredPublication };

export const PUB_PREFS_QUERY_KEY = ["publicationPrefs"] as const;
export const PUBLICATION_SUBSCRIPTIONS_QUERY_KEY = [
  "publicationSubscriptions",
] as const;
export const SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY = [
  "skyreaderFeedSubscriptions",
] as const;

async function refreshSidebarAfterAddingPublication(args: {
  oauthSession: OAuthSession;
  viewerDid: string | null;
  queryClient: QueryClient;
}): Promise<PublicationSidebarProjection> {
  const projection = await refreshPublicationSidebar(args.oauthSession);
  if (args.viewerDid) {
    // Merged, not replaced: the refresh response is the priority tier, so its folder sections
    // carry no publications and would blank every folder if written over the cached projection.
    args.queryClient.setQueryData<PublicationSidebarProjection>(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(args.viewerDid),
      (current) => applySidebarPriorityEvent(current, projection)
    );
  }
  return projection;
}

type PublicationVisibilityRollback = () => Promise<void>;

async function preparePublicationVisibility(args: {
  client: PDSClient;
  publicationId: string;
  hidden: boolean;
}): Promise<PublicationVisibilityRollback> {
  const prefs = await args.client.listPublicationPrefs();
  const existing = prefs
    .filter((row) =>
      publicationIdsMatch(row.value.publicationId, args.publicationId)
    )
    .sort((lhs, rhs) => lhs.uri.localeCompare(rhs.uri))
    .at(-1);
  const previousHidden = existing?.value.hidden ?? false;

  if (previousHidden === args.hidden) return async () => undefined;

  const written = await args.client.upsertPublicationPrefs(
    existing?.value.publicationId ?? args.publicationId,
    { hidden: args.hidden },
    existing ? rkeyFromURI(existing.uri) : undefined
  );
  const writtenRkey = rkeyFromURI(written.uri);

  return async () => {
    if (!existing) {
      await args.client.deletePublicationPrefs(writtenRkey);
      return;
    }
    await args.client.upsertPublicationPrefs(
      existing.value.publicationId,
      { hidden: previousHidden },
      writtenRkey
    );
  };
}

// ── Publication prefs ─────────────────────────────────────────────────────────

/**
 * Returns the user's publication preferences from their PDS.
 */
export function usePublicationPrefs() {
  const client = usePDSClient();
  return useQuery({
    queryKey: PUB_PREFS_QUERY_KEY,
    queryFn: () => client!.listPublicationPrefs(),
    enabled: !!client,
    staleTime: 30_000,
  });
}

export function usePublicationSubscriptions() {
  const client = usePDSClient();
  return useQuery({
    queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY,
    queryFn: () => client!.listPublicationSubscriptions(),
    enabled: !!client,
    staleTime: 30_000,
  });
}

export function useSkyreaderFeedSubscriptions() {
  const client = usePDSClient();
  return useQuery({
    queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY,
    queryFn: () => client!.listSkyreaderFeedSubscriptions(),
    enabled: !!client,
    staleTime: 30_000,
  });
}

/** Fallback when Skyreader subscription has no `customIconUrl` (older records): `/favicon.ico` at site or feed origin. */
function rssPublicationIconFallbackUrl(
  v: SkyreaderFeedSubscriptionRecord,
  normalizedFeedUrl: string
): string | undefined {
  const tryOrigin = (u: string | undefined) => {
    const t = u?.trim();
    if (!t) return undefined;
    try {
      return `${new URL(t).origin}/favicon.ico`;
    } catch {
      return undefined;
    }
  };

  return tryOrigin(v.siteUrl) ?? tryOrigin(normalizedFeedUrl);
}

/** Sidebar rows backed by RSS `feedUrl` on Skyreader subscription records (not Bluesky discovery). */
export function skyreaderSubscriptionsToDiscoveredPublications(
  records: RepoRecord<SkyreaderFeedSubscriptionRecord>[]
): DiscoveredPublication[] {
  const out: DiscoveredPublication[] = [];
  const seenPublicationIds = new Set<string>();

  for (const row of records) {
    const v = row.value;
    const rawUrl = v.feedUrl?.trim();
    if (!rawUrl) continue;
    const src = v.sourceType?.trim().toLowerCase();
    if (src && src !== "rss") continue;

    const normalized = normalizeRssFeedUrlInput(rawUrl);
    if (!normalized) continue;

    const publicationId = rssPublicationIdFromNormalizedFeedUrl(normalized);
    if (seenPublicationIds.has(publicationId)) continue;
    seenPublicationIds.add(publicationId);

    let hostLabel = normalized;
    try {
      hostLabel = new URL(normalized).hostname;
    } catch {
      /* keep string */
    }

    const title =
      v.customTitle?.trim() ||
      v.title?.trim() ||
      hostLabel ||
      "RSS feed";

    const iconFromRecord =
      v.customIconUrl?.trim() ||
      rssPublicationIconFallbackUrl(v, normalized);

    out.push({
      publicationId,
      subscriptionPublicationId: row.uri,
      authorDid: "did:web:skyreader.rss",
      authorHandle: "RSS",
      title,
      ...(iconFromRecord ? { iconUrl: iconFromRecord } : {}),
      discoveredAt: v.updatedAt ?? v.createdAt,
    });
  }

  return out;
}

/** Sidebar rows for graph subscriptions not already present in discovery/RSS rows. */
export function useGraphSubscriptionPublications(
  subscriptions: RepoRecord<{ publication?: string }>[],
  existingRows: DiscoveredPublication[]
) {
  const { getOAuthSession } = useAuth();

  const existingKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const row of existingRows) {
      for (const key of publicationSubscriptionMatchKeys(row)) {
        keys.add(key);
      }
    }
    return keys;
  }, [existingRows]);

  const orphanPublicationUris = useMemo(() => {
    const uris = new Set<string>();
    for (const row of subscriptions) {
      const raw = row.value.publication?.trim();
      if (!raw) continue;
      const normalized = normalizeAtRepoParam(raw);
      const parsed = parseAtUri(normalized);
      if (!parsed || !PUBLICATION_RECORD_COLLECTIONS.has(parsed.collection)) {
        continue;
      }
      const lookup = new Set<string>();
      addPublicationSubscriptionLookupKeys(lookup, normalized);
      if ([...lookup].some((key) => existingKeys.has(key))) continue;
      uris.add(normalized);
    }
    return [...uris].sort();
  }, [subscriptions, existingKeys]);

  return useQuery({
    queryKey: ["graphSubscriptionPublications", orphanPublicationUris],
    queryFn: async (): Promise<DiscoveredPublication[]> => {
      const oauthSession = getOAuthSession();
      const rows = await Promise.all(
        orphanPublicationUris.map((uri) =>
          discoveredPublicationFromAtUri(uri, oauthSession ?? undefined)
        )
      );
      return rows.filter((row): row is DiscoveredPublication => row !== null);
    },
    enabled: orphanPublicationUris.length > 0,
    staleTime: 30_000,
  });
}

// ── Publication prefs mutations ───────────────────────────────────────────────

export function useSetPublicationFolder() {
  const client = usePDSClient();
  const { session } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({
      publicationId,
      folderId,
      existingRkey,
    }: {
      publicationId: string;
      folderId: string | null;
      existingRkey?: string;
    }) => {
      if (!client) {
        throw new Error("Sign in to move publications between folders on your PDS.");
      }
      const result = await client.upsertPublicationPrefs(
        publicationId,
        { folderId },
        existingRkey
      );
      return {
        uri: result.uri,
        rkey: rkeyFromURI(result.uri),
        publicationId,
      };
    },
    onMutate: async ({ publicationId, folderId }) => {
      const did = session?.did;
      if (!did) return undefined;

      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      await qc.cancelQueries({ queryKey });

      const previousProjection =
        qc.getQueryData<PublicationSidebarProjection>(queryKey);
      if (!previousProjection) return undefined;

      const nextProjection = applyPublicationFolderMoveToProjection(
        previousProjection,
        { publicationId, folderId }
      );
      if (nextProjection) {
        qc.setQueryData(queryKey, nextProjection);
      }

      return { previousProjection };
    },
    onError: (_error, _params, context) => {
      const did = session?.did;
      if (!did || !context?.previousProjection) return;
      qc.setQueryData(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
        context.previousProjection
      );
    },
    onSuccess: (written) => {
      const did = session?.did;
      if (!did) return;

      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      qc.setQueryData<PublicationSidebarProjection>(queryKey, (current) => {
        if (!current) return current;
        return reconcilePublicationPrefAfterWrite(
          current,
          written.publicationId,
          written
        );
      });
    },
  });
}

export function useSubscribeToPublication() {
  const client = usePDSClient();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async ({
      publication,
    }: {
      publication: DiscoveredPublication;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      const target = standardSiteSubscriptionTargetFromDiscovery(publication);
      if (!target) {
        throw new Error(
          "This account does not expose a standard.site publication record we can subscribe to."
        );
      }
      const rollbackVisibility = await preparePublicationVisibility({
        client,
        publicationId: publication.publicationId,
        hidden: false,
      });
      try {
        await client.createPublicationSubscription({ publication: target });
      } catch (error) {
        await rollbackVisibility().catch(() => undefined);
        throw error;
      }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: PUB_PREFS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY });
    },
  });
}

export function useUnsubscribePublication() {
  const client = usePDSClient();
  const qc = useQueryClient();
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;

  return useMutation({
    mutationFn: async ({
      publication,
    }: {
      publication: DiscoveredPublication;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");

      const subUri = publication.subscriptionPublicationId?.trim();
      let subscriptionKind: "rss" | "standard" | null = null;
      let subscriptionRkey: string | null = null;
      if (subUri) {
        const parsed = parseAtUri(normalizeAtRepoParam(subUri));
        if (parsed?.collection === COLLECTION_SKYREADER_FEED_SUBSCRIPTION) {
          subscriptionKind = "rss";
          subscriptionRkey = parsed.rkey;
        }
        if (parsed?.collection === COLLECTION_STANDARD_SITE_SUBSCRIPTION) {
          subscriptionKind = "standard";
          subscriptionRkey = parsed.rkey;
        }
      }

      if (!subscriptionKind) {
        const subs = await qc.fetchQuery({
          queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY,
          queryFn: () => client.listPublicationSubscriptions(),
        });

        const matchKeys = new Set(publicationSubscriptionMatchKeys(publication));
        for (const row of subs) {
          const pubRef = row.value.publication?.trim();
          if (!pubRef) continue;
          const expanded = new Set<string>();
          addPublicationSubscriptionLookupKeys(expanded, pubRef);
          let matched = false;
          for (const k of expanded) {
            if (matchKeys.has(k)) {
              matched = true;
              break;
            }
          }
          if (matched) {
            subscriptionKind = "standard";
            subscriptionRkey = rkeyFromURI(row.uri);
            break;
          }
        }
      }

      if (!subscriptionKind || !subscriptionRkey) {
        throw new Error("No subscription record found for this publication.");
      }

      if (subscriptionKind === "rss") {
        await client.deleteSkyreaderFeedSubscription(subscriptionRkey);
        return;
      }

      const rollbackVisibility = await preparePublicationVisibility({
        client,
        publicationId: publication.publicationId,
        hidden: true,
      });
      try {
        await client.deletePublicationSubscription(subscriptionRkey);
      } catch (error) {
        await rollbackVisibility().catch(() => undefined);
        throw error;
      }
    },
    onSuccess: (_result, { publication }) => {
      if (did) {
        const sidebarQueryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
        qc.setQueryData<PublicationSidebarProjection>(
          sidebarQueryKey,
          (current) =>
            removePublicationFromSidebarProjection(
              current,
              publication.publicationId
            )
        );
        removePublicationFromEntryCaches(qc, did, publication);
      }

      qc.invalidateQueries({ queryKey: PUB_PREFS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY });

      const oauth = getOAuthSession();
      if (!oauth || !did) return;
      void refreshPublicationSidebar(oauth)
        .then((projection) => {
          // Priority-tier payload — merge so folder contents survive. See
          // `refreshPublicationSidebar`.
          qc.setQueryData<PublicationSidebarProjection>(
            PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
            (current) => applySidebarPriorityEvent(current, projection)
          );
          removePublicationFromEntryCaches(qc, did, publication);
          return qc.invalidateQueries({
            predicate: ({ queryKey }) =>
              queryKey[0] === "aggregateEntries" && queryKey[1] === did,
          });
        })
        .catch(() => {
          /* The optimistic eviction remains until the next authoritative refresh. */
        });
    },
  });
}

export function useCreateSkyreaderFeedSubscription() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: { feedUrl: string; title?: string }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      const normalized = normalizeRssFeedUrlInput(input.feedUrl);
      if (!normalized) {
        throw new Error("Enter a valid feed URL");
      }
      const siteHost = (() => {
        try {
          return new URL(normalized).origin;
        } catch {
          return undefined;
        }
      })();

      return client.createSkyreaderFeedSubscription({
        feedUrl: normalized,
        title: input.title?.trim() || undefined,
        siteUrl: siteHost,
      });
    },
    onSuccess: () =>
      qc.invalidateQueries({
        queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY,
      }),
  });
}

export function useRefreshSkyreaderSubscriptionIcon() {
  const client = usePDSClient();
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async ({
      publication,
    }: {
      publication: DiscoveredPublication;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      if (!isRssPublicationId(publication.publicationId)) {
        throw new Error("Only RSS publications support favicon refresh.");
      }

      const feedUrl = normalizedFeedUrlFromRssPublicationId(publication.publicationId);
      if (!feedUrl?.trim()) throw new Error("Invalid RSS publication id.");

      const subUri = publication.subscriptionPublicationId?.trim();
      if (!subUri) throw new Error("Missing Skyreader subscription record.");

      const parsed = parseAtUri(normalizeAtRepoParam(subUri));
      if (
        !parsed ||
        parsed.collection !== COLLECTION_SKYREADER_FEED_SUBSCRIPTION
      ) {
        throw new Error("Publication is not backed by a Skyreader subscription.");
      }

      const qs = new URLSearchParams({
        url: feedUrl.trim(),
        brandingOnly: "1",
      });
      const res = await fetch(`/api/rss-feed?${qs.toString()}`);
      const json = (await res.json()) as {
        error?: string;
        feedIconUrl?: string;
        faviconFallbackUrl?: string;
        siteUrl?: string;
      };

      if (!res.ok) {
        throw new Error(
          typeof json.error === "string" ? json.error : "Could not fetch feed branding."
        );
      }

      const icon =
        typeof json.feedIconUrl === "string" && json.feedIconUrl.trim()
          ? json.feedIconUrl.trim()
          : typeof json.faviconFallbackUrl === "string" && json.faviconFallbackUrl.trim()
            ? json.faviconFallbackUrl.trim()
            : null;

      const sitePatch =
        typeof json.siteUrl === "string" && json.siteUrl.trim()
          ? json.siteUrl.trim()
          : undefined;

      await client.updateSkyreaderFeedSubscription({
        rkey: parsed.rkey,
        customIconUrl: icon,
        ...(sitePatch !== undefined ? { siteUrl: sitePatch } : {}),
      });
    },
    onSuccess: () =>
      qc.invalidateQueries({
        queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY,
      }),
  });
}

/**
 * Resolve a pasted link (https, AT-URI, handle, DID) then create either
 * `site.standard.graph.subscription` or Skyreader RSS subscription on the PDS.
 */
export function useAddPublicationFromAnyLink() {
  const qc = useQueryClient();
  const client = usePDSClient();
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;

  return useMutation({
    mutationFn: async (input: {
      link: string;
      title?: string;
      resolved?: ResolveAddPublicationPayload;
    }) => {
      if (!client) throw new Error("OAuth session required");
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const { resolveAddPublicationOnGateway } = await import(
        "@/lib/publicationProjectionClient"
      );
      const resolved = input.resolved;
      const gatewayResult = resolved
        ? resolved
        : await resolveAddPublicationOnGateway(oauth, input.link).then(
            (gateway) => {
              if (gateway.error) throw new Error(gateway.error);
              if (!gateway.result) throw new Error("Could not resolve link");
              return gateway.result;
            }
          );
      if (gatewayResult.kind === "standard-site") {
        const rollbackVisibility = await preparePublicationVisibility({
          client,
          publicationId: gatewayResult.publicationAtUri,
          hidden: false,
        });
        try {
          await client.createPublicationSubscription({
            publication: gatewayResult.publicationAtUri,
          });
        } catch (error) {
          await rollbackVisibility().catch(() => undefined);
          throw error;
        }
        void refreshSidebarAfterAddingPublication({
          oauthSession: oauth,
          viewerDid: did,
          queryClient: qc,
        }).catch(() => {
          if (did) {
            void qc.invalidateQueries({
              queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
            });
          }
        });
        return {
          kind: "standard-site" as const,
          navigatePubId: gatewayResult.publicationAtUri,
          authorDid: publicationRepoDid(gatewayResult.publicationAtUri),
        };
      }
      if (gatewayResult.kind === "rss") {
        const normalized = normalizeRssFeedUrlInput(gatewayResult.feedUrl);
        if (!normalized) throw new Error("Invalid feed URL from resolver");
        await client.createSkyreaderFeedSubscription({
          feedUrl: normalized,
          title: input.title?.trim() || gatewayResult.title,
          siteUrl: gatewayResult.siteUrl,
        });
        const navigatePubId = rssPublicationIdFromNormalizedFeedUrl(normalized);
        void (async () => {
          await enrollAuthorsInAppView(oauth, [], [normalized]);
          await refreshSidebarAfterAddingPublication({
            oauthSession: oauth,
            viewerDid: did,
            queryClient: qc,
          });
          if (!did) return;
          const firstPage = await fetchEntriesInfinitePage({
            normalizedPublicationKey: navigatePubId,
            pageParam: undefined,
            oauthSession: oauth,
            viewerDid: did,
            queryClient: qc,
            skipEnroll: true,
          });
          qc.setQueryData<InfiniteData<EntriesPage>>(
            [...ENTRIES_QUERY_KEY(did, navigatePubId), "all"],
            { pages: [firstPage], pageParams: [undefined] }
          );
        })().catch(() => {
          if (did) {
            void qc.invalidateQueries({
              queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
            });
          }
        });
        return {
          kind: "rss" as const,
          navigatePubId,
        };
      }
      throw new Error("Could not resolve link");
    },
    onSuccess: (result) => {
      qc.invalidateQueries({ queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: ["graphSubscriptionPublications"] });
      const oauthSession = getOAuthSession();
      if (
        result?.kind === "standard-site" &&
        typeof result.authorDid === "string" &&
        oauthSession
      ) {
        void enrollAuthorsInAppView(oauthSession, [result.authorDid]).catch(
          () => undefined
        );
      }
    },
  });
}

export function useResolvePublicationForAdd() {
  const { getOAuthSession } = useAuth();

  return useMutation({
    mutationFn: async (input: string): Promise<ResolveAddPublicationPayload> => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const { resolveAddPublicationOnGateway } = await import(
        "@/lib/publicationProjectionClient"
      );
      const response = await resolveAddPublicationOnGateway(oauth, input);
      if (response.error) throw new Error(response.error);
      if (!response.result) throw new Error("Could not resolve publication");
      return response.result;
    },
  });
}
