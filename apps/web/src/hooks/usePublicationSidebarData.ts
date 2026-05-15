"use client";

import { useCallback, useMemo } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import {
  useDiscovery,
  usePublicationPrefs,
  usePublicationSubscriptions,
  useRefreshDiscovery,
  useSkyreaderFeedSubscriptions,
  skyreaderSubscriptionsToDiscoveredPublications,
} from "@/hooks/usePublications";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { viewerOwnsDiscoveredPublication } from "@/lib/atprotoClient";
import {
  addPublicationSubscriptionLookupKeys,
  publicationSubscriptionMatchKeys,
} from "@/lib/publicationSubscriptionMatch";
import type { PublicationPrefsRecord, RepoRecord } from "@/lib/pdsClient";

/** Shared discovery/subscription derivation for sidebar + `/me/publications`. */
export function usePublicationSidebarData() {
  const { session } = useAuth();

  const { data: folders = [], isLoading: foldersLoading } = useFolders();
  const { data: publications = [], isLoading: pubsLoading } = useDiscovery();
  const { data: prefs = [] } = usePublicationPrefs();
  const { data: subscriptions = [], isLoading: subscriptionsLoading } =
    usePublicationSubscriptions();
  const { data: skyreaderRecords = [], isLoading: skyreaderSubsLoading } =
    useSkyreaderFeedSubscriptions();
  const subscriptionsBlockLoading = subscriptionsLoading || skyreaderSubsLoading;
  const refresh = useRefreshDiscovery();

  const prefsMap = useMemo(
    () =>
      new Map<string, RepoRecord<PublicationPrefsRecord>>(
        prefs.map((p) => [p.value.publicationId, p])
      ),
    [prefs]
  );

  const visiblePubs = useMemo(
    () =>
      publications.filter((p) => {
        const pref = prefsMap.get(p.publicationId);
        return !pref?.value.hidden;
      }),
    [publications, prefsMap]
  );

  const rssPublicationRows = useMemo(
    () => skyreaderSubscriptionsToDiscoveredPublications(skyreaderRecords),
    [skyreaderRecords]
  );

  const allPublicationRows = useMemo(
    () => [...publications, ...rssPublicationRows],
    [publications, rssPublicationRows]
  );

  const rssPublicationRowsVisible = useMemo(
    () =>
      rssPublicationRows.filter((p) => !prefsMap.get(p.publicationId)?.value.hidden),
    [rssPublicationRows, prefsMap]
  );

  const viewerDid = session?.did;

  const subscriptionPublicationKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const subscription of subscriptions) {
      addPublicationSubscriptionLookupKeys(keys, subscription.value.publication);
    }
    return keys;
  }, [subscriptions]);

  const isSubscribedPublication = useCallback(
    (pub: (typeof visiblePubs)[number]) =>
      publicationSubscriptionMatchKeys(pub).some((key) =>
        subscriptionPublicationKeys.has(key)
      ),
    [subscriptionPublicationKeys]
  );

  const { graphSubscribedPubs, followOwnedUnsubscribedPubs } = useMemo(() => {
    const graphSubscribedPubsInner: typeof visiblePubs = [];
    const followOwnedUnsubscribedPubsInner: typeof visiblePubs = [];

    if (!viewerDid) {
      return {
        graphSubscribedPubs: graphSubscribedPubsInner,
        followOwnedUnsubscribedPubs: followOwnedUnsubscribedPubsInner,
      };
    }

    for (const pub of visiblePubs) {
      if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        graphSubscribedPubsInner.push(pub);
      } else if (isSubscribedPublication(pub)) {
        graphSubscribedPubsInner.push(pub);
      } else {
        followOwnedUnsubscribedPubsInner.push(pub);
      }
    }

    return {
      graphSubscribedPubs: graphSubscribedPubsInner,
      followOwnedUnsubscribedPubs: followOwnedUnsubscribedPubsInner,
    };
  }, [visiblePubs, viewerDid, isSubscribedPublication]);

  const subscribedPubs = useMemo(() => {
    const merged: DiscoveredPublication[] = [...graphSubscribedPubs];
    const ids = new Set(graphSubscribedPubs.map((p) => p.publicationId));
    for (const r of rssPublicationRowsVisible) {
      if (!ids.has(r.publicationId)) {
        merged.push(r);
        ids.add(r.publicationId);
      }
    }
    return merged;
  }, [graphSubscribedPubs, rssPublicationRowsVisible]);

  const { folderMap, myPublications, unfolderedPubs } = useMemo(() => {
    const folderMapInner = new Map<string, typeof subscribedPubs>();
    const myPublicationsInner: typeof subscribedPubs = [];
    const unfolderedPubsInner: typeof subscribedPubs = [];

    for (const pub of subscribedPubs) {
      if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        myPublicationsInner.push(pub);
        continue;
      }

      const pref = prefsMap.get(pub.publicationId);
      const folderId = pref?.value.folderId;
      if (folderId) {
        const list = folderMapInner.get(folderId) ?? [];
        list.push(pub);
        folderMapInner.set(folderId, list);
        continue;
      }

      unfolderedPubsInner.push(pub);
    }

    return {
      folderMap: folderMapInner,
      myPublications: myPublicationsInner,
      unfolderedPubs: unfolderedPubsInner,
    };
  }, [subscribedPubs, prefsMap, viewerDid]);

  const followingTabPublications = useMemo(() => {
    const myPublicationIds = new Set(myPublications.map((pub) => pub.publicationId));
    return followOwnedUnsubscribedPubs.filter(
      (pub) => !myPublicationIds.has(pub.publicationId)
    );
  }, [followOwnedUnsubscribedPubs, myPublications]);

  const sidebarListsLoading =
    foldersLoading || pubsLoading || subscriptionsBlockLoading;

  return {
    folders,
    foldersLoading,
    prefsMap,
    allPublicationRows,
    folderMap,
    myPublications,
    unfolderedPubs,
    followingTabPublications,
    pubsLoading,
    subscriptionsBlockLoading,
    sidebarListsLoading,
    refresh,
    viewerDid,
  };
}
