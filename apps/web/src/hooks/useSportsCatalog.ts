"use client";

import { useCallback, useEffect, useSyncExternalStore } from "react";
import { useQuery } from "@tanstack/react-query";
import { getSportsCatalog } from "@/lib/sportsFeedClient";
import { getAppEnv } from "@/lib/appEnv";
import { browserSportsVisibility, rememberBrowserSportsVisibility, SPORTS_VISIBILITY_MAX_AGE_MS, subscribeSportsVisibility } from "@/lib/sportsTopicVisibility";

export function useSportsCatalog() {
  const catalog = useQuery({queryKey:["sportsCatalog"],queryFn:({signal})=>getSportsCatalog(signal),staleTime:5*60000,retry:1});
  const environment = getAppEnv();
  const snapshot = useCallback(() => browserSportsVisibility(environment), [environment]);
  const confirmed = useSyncExternalStore(subscribeSportsVisibility, snapshot, () => undefined);
  useEffect(() => {
    if (typeof catalog.data?.enabled !== "boolean" || !catalog.dataUpdatedAt) return;
    rememberBrowserSportsVisibility(environment, catalog.data.enabled, catalog.dataUpdatedAt);
    // Wake subscribers when the last server confirmation expires during a long-lived outage.
    const remaining = catalog.dataUpdatedAt + SPORTS_VISIBILITY_MAX_AGE_MS - Date.now();
    if (remaining <= 0) return;
    const timer = setTimeout(() => rememberBrowserSportsVisibility(environment, catalog.data!.enabled, catalog.dataUpdatedAt), remaining);
    return () => clearTimeout(timer);
  }, [environment, catalog.data, catalog.dataUpdatedAt]);
  return {...catalog, confirmedEnabled: catalog.data?.enabled === false ? false : confirmed === true};
}
