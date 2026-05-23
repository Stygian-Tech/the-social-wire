"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { usePDSClient } from "./usePDSClient";
import { useAuth } from "./useAuth";
import {
  discoverPublications,
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
  type RepoRecord,
  rkeyFromURI,
  type SkyreaderFeedSubscriptionRecord,
} from "@/lib/pdsClient";
import {
  addPublicationSubscriptionLookupKeys,
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
  enrollAuthorsInAppView,
  isThinAppViewEnabled,
} from "@/lib/thinAppViewClient";

export type { DiscoveredPublication };

export const PUB_PREFS_QUERY_KEY = ["publicationPrefs"] as const;
export const PUBLICATION_SUBSCRIPTIONS_QUERY_KEY = [
  "publicationSubscriptions",
] as const;
export const SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY = [
  "skyreaderFeedSubscriptions",
] as const;
export const DISCOVERY_QUERY_KEY = (did: string) =>
  ["discovery", "publications-v2", did] as const;

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

/** Fire-and-forget enrollment of followed author DIDs into the thin AppView index. */
function maybeEnrollDiscoveryAuthors(
  oauthSession: OAuthSession | null,
  publications: DiscoveredPublication[]
): void {
  if (!isThinAppViewEnabled() || !oauthSession) return;
  const authorDids = [
    ...new Set(
      publications
        .map((p) => p.authorDid?.trim())
        .filter((did): did is string => Boolean(did))
    ),
  ];
  if (authorDids.length === 0) return;
  void enrollAuthorsInAppView(oauthSession, authorDids).catch(() => {
    /* best-effort backfill */
  });
}

// ── Discovery ─────────────────────────────────────────────────────────────────

/**
 * Returns all publications discovered from the user's follow graph.
 */
export function useDiscovery() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;
  const qc = useQueryClient();

  return useQuery({
    queryKey: DISCOVERY_QUERY_KEY(did ?? ""),
    queryFn: async ({ signal }): Promise<DiscoveredPublication[]> => {
      const oauthSession = getOAuthSession();
      if (!did || !oauthSession) return [];
      return discoverPublications(did, oauthSession, {
        signal,
        onProgress: (list) =>
          qc.setQueryData(DISCOVERY_QUERY_KEY(did), list),
      }).then((list) => {
        maybeEnrollDiscoveryAuthors(oauthSession, list);
        return list;
      });
    },
    enabled: !!did && !!session,
    /** Long TTL — hydrated from localStorage; user refreshes explicitly via sidebar control. */
    staleTime: 1000 * 60 * 60 * 6,
    gcTime: 1000 * 60 * 60 * 24 * 7,
    refetchOnWindowFocus: false,
  });
}

/**
 * Re-runs discovery by invalidating the cached results, triggering a fresh fetch.
 */
export function useRefreshDiscovery() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (): Promise<DiscoveredPublication[]> => {
      const oauthSession = getOAuthSession();
      if (!did || !oauthSession) throw new Error("Not authenticated");
      return discoverPublications(did, oauthSession, {
        onProgress: (list) =>
          qc.setQueryData(DISCOVERY_QUERY_KEY(did), list),
      }).then((list) => {
        maybeEnrollDiscoveryAuthors(oauthSession, list);
        return list;
      });
    },
  });
}

// ── Publication prefs mutations ───────────────────────────────────────────────

export function useSetPublicationFolder() {
  const { session, getOAuthSession } = useAuth();
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
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const { upsertPublicationPrefsOnGateway } = await import(
        "@/lib/publicationProjectionClient"
      );
      return upsertPublicationPrefsOnGateway(oauth, {
        publicationId,
        folderId,
        existingRkey,
      });
    },
    onSuccess: () => {
      if (session?.did) {
        qc.invalidateQueries({
          queryKey: ["publicationSidebarProjection", session.did],
        });
      }
    },
  });
}

export function useSubscribeToPublication() {
  const client = usePDSClient();
  const qc = useQueryClient();
  const { session } = useAuth();
  const did = session?.did ?? null;

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
      await client.createPublicationSubscription({ publication: target });
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY });
      if (did) qc.invalidateQueries({ queryKey: DISCOVERY_QUERY_KEY(did) });
    },
  });
}

export function useUnsubscribePublication() {
  const client = usePDSClient();
  const qc = useQueryClient();
  const { session } = useAuth();
  const did = session?.did ?? null;

  return useMutation({
    mutationFn: async ({
      publication,
    }: {
      publication: DiscoveredPublication;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");

      const subUri = publication.subscriptionPublicationId?.trim();
      if (subUri) {
        const parsed = parseAtUri(normalizeAtRepoParam(subUri));
        if (parsed?.collection === COLLECTION_SKYREADER_FEED_SUBSCRIPTION) {
          await client.deleteSkyreaderFeedSubscription(parsed.rkey);
          return;
        }
        if (parsed?.collection === COLLECTION_STANDARD_SITE_SUBSCRIPTION) {
          await client.deletePublicationSubscription(parsed.rkey);
          return;
        }
      }

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
          await client.deletePublicationSubscription(rkeyFromURI(row.uri));
          return;
        }
      }

      throw new Error("No subscription record found for this publication.");
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY });
      if (did) qc.invalidateQueries({ queryKey: DISCOVERY_QUERY_KEY(did) });
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
    mutationFn: async (input: { link: string; title?: string }) => {
      if (!client) throw new Error("OAuth session required");
      const { resolveAddPublicationOnGateway } = await import(
        "@/lib/publicationProjectionClient"
      );
      const gateway = await resolveAddPublicationOnGateway(
        getOAuthSession()!,
        input.link
      );
      if (gateway.error) throw new Error(gateway.error);
      if (gateway.result?.kind === "standard-site") {
        await client.createPublicationSubscription({
          publication: gateway.result.publicationAtUri,
        });
        return {
          kind: "standard-site" as const,
          navigatePubId: gateway.result.publicationAtUri,
          authorDid: publicationRepoDid(gateway.result.publicationAtUri),
        };
      }
      if (gateway.result?.kind === "rss") {
        const normalized = normalizeRssFeedUrlInput(gateway.result.feedUrl);
        if (!normalized) throw new Error("Invalid feed URL from resolver");
        await client.createSkyreaderFeedSubscription({
          feedUrl: normalized,
          title: input.title?.trim() || gateway.result.title,
          siteUrl: gateway.result.siteUrl,
        });
        return {
          kind: "rss" as const,
          navigatePubId: rssPublicationIdFromNormalizedFeedUrl(normalized),
        };
      }
      throw new Error("Could not resolve link");
    },
    onSuccess: (result) => {
      qc.invalidateQueries({ queryKey: PUBLICATION_SUBSCRIPTIONS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: SKYREADER_FEED_SUBSCRIPTIONS_QUERY_KEY });
      qc.invalidateQueries({ queryKey: ["graphSubscriptionPublications"] });
      if (did) {
        qc.invalidateQueries({ queryKey: DISCOVERY_QUERY_KEY(did) });
        qc.invalidateQueries({
          queryKey: ["publicationSidebarProjection", did],
        });
      }
      const oauthSession = getOAuthSession();
      if (
        result?.kind === "standard-site" &&
        typeof result.authorDid === "string" &&
        oauthSession
      ) {
        maybeEnrollDiscoveryAuthors(oauthSession, [
          {
            publicationId: result.navigatePubId,
            authorDid: result.authorDid,
            authorHandle: result.authorDid,
            title: "",
            discoveredAt: new Date().toISOString(),
          },
        ]);
      }
    },
  });
}
