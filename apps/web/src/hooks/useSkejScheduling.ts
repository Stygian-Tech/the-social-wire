"use client";

import type { ArticlePublishInput } from "@/lib/articles/articlePublishingTypes";
import { listArticlePublications } from "@/lib/articles/articlePublishingClient";
import { prepareScheduledArticle } from "@/lib/articles/articleSchedulingPreparation";
import { ArticleSchedulingNotSubmittedError } from "@/lib/articles/articleSchedulingError";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { useProEntitlements } from "@/hooks/useProEntitlements";
import { requirePro } from "@/lib/proEntitlements";
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { useBrandAccounts } from "@/hooks/useBrandAccounts";
import { getStoredOAuthDid } from "@/lib/auth";
import { listBrandAccounts, onBrandAccountsChanged, restoreBrandAccount } from "@/lib/brandAccounts/brandAccountSessions";
import { getSkejEnvironment } from "@/lib/skej/skejEnvironment";
import { cancelSkejSchedule, createSkejSchedule, createSkejArticleSchedule, getSkejSchedulingReadiness, listSkejSchedules, rescheduleSkejPost, type SkejScheduleSummary } from "@/lib/skej/skejSchedulingClient";

export function useSkejScheduling(ownerDid: string, actorDid: string, options: { enabled?: boolean; includeSchedules?: boolean } = {}) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const { isPro } = useProEntitlements();
  const access = useRef(isPro);
  useLayoutEffect(() => { access.current = isPro; }, [isPro]);
  const accounts = useBrandAccounts(ownerDid);
  const client = useQueryClient();
  const linkage = useRef(0);
  const [revision, setRevision] = useState(0);
  useLayoutEffect(() => onBrandAccountsChanged(() => { linkage.current++; setRevision(linkage.current); }), []);
  const generation = useMemo(() => ({ ownerDid, actorDid, oauthSessionReloadSeq, revision }), [ownerDid, actorDid, oauthSessionReloadSeq, revision]);
  const current = useRef({ ownerDid, actorDid, mounted: true, generation });
  const writing = useRef(false);
  useLayoutEffect(() => {
    current.current = { ownerDid, actorDid, mounted: true, generation };
    return () => { current.current.mounted = false; };
  }, [ownerDid, actorDid, generation]);
  function assertCurrentActor() {
    if (!access.current) throw new Error("This Feature Requires Social Wire Pro.");
    const identity = current.current;
    if (linkage.current !== revision || identity.generation !== generation || !identity.mounted || identity.ownerDid !== ownerDid || identity.actorDid !== actorDid || session?.did !== ownerDid || getOAuthSession()?.did !== ownerDid || getStoredOAuthDid() !== ownerDid) throw new Error("Your Account Changed. Reopen the Content Calendar.");
    if (actorDid !== ownerDid && !listBrandAccounts(ownerDid).includes(actorDid)) throw new Error("This Brand Account Is No Longer Linked.");
  }
  async function requireActor() {
    assertCurrentActor();
    await requirePro(getOAuthSession()!);
    assertCurrentActor();
    const oauth = actorDid === ownerDid ? getOAuthSession()! : await restoreBrandAccount(ownerDid, actorDid);
    assertCurrentActor();
    if (oauth.did !== actorDid) throw new Error("The Scheduling Account Does Not Match.");
    return { session: oauth, assertCurrentActor };
  }
  const key = ["skejScheduling", ownerDid, actorDid, oauthSessionReloadSeq, revision] as const;
  const enabled = isPro && options.enabled !== false && !!ownerDid && !!actorDid && session?.did === ownerDid && (actorDid === ownerDid || accounts.includes(actorDid));
  const readiness = useQuery({ queryKey: [...key, "readiness"], enabled, retry: false, staleTime: 30_000,
    queryFn: async ({ signal }) => getSkejSchedulingReadiness(await requireActor(), signal) });
  const schedules = useQuery({ queryKey: [...key, "schedules"], enabled: enabled && options.includeSchedules !== false && readiness.data?.connected === true, retry: false, staleTime: 15_000,
    queryFn: async ({ signal }) => listSkejSchedules(await requireActor(), signal) });
  const mutation = useMutation({
    mutationFn: async (action: { kind: "create"; text: string; scheduledAt: string; linkPreview?: ComposeLinkPreview } | { kind: "article"; input: ArticlePublishInput; scheduledAt: string } | { kind: "cancel"; item: SkejScheduleSummary } | { kind: "reschedule"; item: SkejScheduleSummary; scheduledAt: string }) => {
      if (writing.current) throw new Error("A Scheduling Request Is Already in Progress.");
      writing.current = true;
      let articleSubmitted = false;
      try {
        const actor = await requireActor();
        const connected = await getSkejSchedulingReadiness(actor);
        actor.assertCurrentActor();
        if (!connected.connected) throw new Error("Connect This Account to Skej to Enable Scheduling.");
        if (action.kind === "article") {
          if (!action.input.publication.uri.startsWith(`at://${actor.session.did}/site.standard.publication/`)) throw new Error("Choose a Publication Owned by This Account.");
          const publications = await listArticlePublications(actor.session);
          actor.assertCurrentActor();
          const publication = publications.find(item => item.uri === action.input.publication.uri);
          if (!publication) throw new Error("This Publication Is No Longer Available.");
          const prepared = await prepareScheduledArticle({ ...action.input, publication }, action.scheduledAt);
          actor.assertCurrentActor();
          articleSubmitted = true;
          return await createSkejArticleSchedule(actor, prepared.record, prepared.publishRkey, action.scheduledAt);
        }
        if (action.kind === "create") return await createSkejSchedule(actor, action.text, action.scheduledAt, action.linkPreview);
        if (action.kind === "cancel") return await cancelSkejSchedule(actor, action.item);
        return await rescheduleSkejPost(actor, action.item, action.scheduledAt);
      } catch (error) {
        if (action.kind === "article" && !articleSubmitted) throw new ArticleSchedulingNotSubmittedError(error);
        throw error;
      } finally { writing.current = false; }
    },
    onSuccess: () => { if (current.current.mounted && current.current.ownerDid === ownerDid && current.current.actorDid === actorDid) void client.invalidateQueries({ queryKey: key }); },
  });
  const connect = new URL(getSkejEnvironment().connectUrl);
  connect.searchParams.set("handle", actorDid);
  connect.searchParams.set("returnTo", "/scheduling/connected");
  return { readiness, schedules, connectUrl: connect.href, pending: mutation.isPending,
    scheduleArticle: (input: ArticlePublishInput, scheduledAt: string) => mutation.mutateAsync({ kind: "article", input, scheduledAt }),
    schedule: (text: string, scheduledAt: string, linkPreview?: ComposeLinkPreview) => mutation.mutateAsync({ kind: "create", text, scheduledAt, linkPreview }),
    cancel: async (item: SkejScheduleSummary) => { await mutation.mutateAsync({ kind: "cancel", item }); },
    reschedule: async (item: SkejScheduleSummary, scheduledAt: string) => { await mutation.mutateAsync({ kind: "reschedule", item, scheduledAt }); },
  };
}
