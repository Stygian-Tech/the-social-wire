"use client";

import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { listArticlePublications } from "@/lib/articles/articlePublishingClient";
import { createEvent, getEvent, listEvents, publishLiveUpdate } from "@/lib/livePosts/livePostClient";
import { listViewerAtmoEvents } from "@/lib/livePosts/atmoEventClient";
import type { LiveEvent, LiveEventInput } from "@/lib/livePosts/livePostTypes";

export function useLivePosts() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did;
  const activeDid = useRef(did);
  const mounted = useRef(true);
  const lock = useRef(false);
  const retryIds = useRef(new Map<string, { operationId: string; createdAt: string }>());
  const [operation, setOperation] = useState<{ did?: string; pending: boolean; error?: Error }>({ pending: false });
  const cache = useQueryClient();
  const queryKey = ["livePosts", did] as const;
  useLayoutEffect(() => {
    activeDid.current = did;
    mounted.current = true;
    return () => { mounted.current = false; };
  }, [did]);
  const requireSession = useCallback(() => {
    const oauth = getOAuthSession();
    if (!did || !oauth || oauth.did !== did || activeDid.current !== did) throw new Error("Sign In Again Before Using Live Post.");
    return oauth;
  }, [did, getOAuthSession]);
  const events = useQuery({ queryKey, queryFn: ({ signal }) => listEvents(requireSession(), signal), enabled: !!did, staleTime: 15_000, retry: 1 });
  const publications = useQuery({ queryKey: ["articlePublications", did], queryFn: ({ signal }) => listArticlePublications(requireSession(), signal), enabled: !!did, staleTime: 60_000, retry: 1 });
  const rsvp = useQuery({ queryKey: ["atmoEvents", did], queryFn: ({ signal }) => listViewerAtmoEvents(requireSession(), signal), enabled: !!did, staleTime: 60_000, retry: 1 });
  const run = useCallback(async <T,>(action: () => Promise<T>): Promise<T> => {
    requireSession();
    if (lock.current) throw new Error("Wait For The Current Live Post Operation.");
    lock.current = true;
    setOperation({ did, pending: true });
    try {
      const result = await action();
      if (!mounted.current || activeDid.current !== did) throw new Error("Your Account Changed. Reopen Live Post.");
      // A cache refresh must never turn a committed PDS write into a failed publish.
      void cache.invalidateQueries({ queryKey: ["livePosts", did] }).catch(() => undefined);
      return result;
    } catch (failure) {
      if (mounted.current && activeDid.current === did) setOperation({ did, pending: true, error: failure instanceof Error ? failure : new Error("Live Post Could Not Be Saved.") });
      throw failure;
    } finally {
      lock.current = false;
      if (mounted.current && activeDid.current === did) setOperation(previous => ({ ...previous, pending: false }));
    }
  }, [cache, did, requireSession]);
  const create = useCallback((input: LiveEventInput) => run(async () => {
    const key = JSON.stringify(["create", did, input]);
    const attempt = retryIds.current.get(key) ?? { operationId: crypto.randomUUID(), createdAt: new Date().toISOString() };
    retryIds.current.set(key, attempt);
    const result = await createEvent(requireSession(), input, { ...attempt, assertCurrentAccount: () => { requireSession(); } });
    retryIds.current.delete(key);
    cache.setQueryData<LiveEvent[]>(["livePosts", did], previous => [result, ...(previous ?? []).filter(event => event.uri !== result.uri)]);
    return result;
  }), [cache, did, requireSession, run]);
  const publish = useCallback((eventUri: string, text: string) => run(async () => {
    const oauth = requireSession();
    const key = JSON.stringify([did, eventUri, text]);
    const attempt = retryIds.current.get(key) ?? { operationId: crypto.randomUUID(), createdAt: new Date().toISOString() };
    retryIds.current.set(key, attempt);
    const event = await getEvent(oauth, eventUri);
    const result = await publishLiveUpdate(oauth, event, text, { ...attempt, assertCurrentAccount: () => { requireSession(); } });
    retryIds.current.delete(key);
    cache.setQueryData<LiveEvent[]>(["livePosts", did], previous => [result, ...(previous ?? []).filter(event => event.uri !== result.uri)]);
    return result;
  }), [cache, did, requireSession, run]);
  return {
    events: events.data ?? [], loading: events.isPending && !!did,
    error: (operation.did === did ? operation.error : undefined) ?? events.error,
    pending: operation.did === did && operation.pending,
    publications: publications.data ?? [], publicationsLoading: publications.isPending && !!did,
    publicationsError: publications.error,
    rsvpEvents: rsvp.data ?? [], rsvpLoading: rsvp.isPending && !!did, rsvpError: rsvp.error,
    refresh: async () => { await Promise.all([events.refetch(), publications.refetch(), rsvp.refetch()]); },
    createEvent: create, publishUpdate: publish,
  };
}
