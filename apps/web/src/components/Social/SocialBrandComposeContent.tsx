"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { useSkejScheduling } from "@/hooks/useSkejScheduling";
import { scheduledInstant } from "@/components/ContentCalendar/calendarDates";
import { ScheduleTimingControls } from "./ScheduleTimingControls";
import { SchedulingReadiness } from "./SchedulingReadiness";
import { useBrandAccountSession } from "@/hooks/useBrandAccounts";
import { createAuthenticatedAppViewAgent, getBlueskySocialCatalog } from "@/lib/blueskySocialClient";
import { publishBrandPost } from "@/lib/brandAccounts/brandAccountSocialClient";
import { BrandPostComposer } from "@/components/BrandAccounts/BrandPostComposer";
import { Button } from "@/components/ui/button";

export function SocialBrandComposeContent({ ownerDid, actorDid, onPendingChange, onPublished, close }: { ownerDid: string; actorDid: string; onPendingChange: (pending: boolean) => void; onPublished: (scheduled: boolean) => void; close: () => void }) {
  const connection = useBrandAccountSession(ownerDid, actorDid);
  const cache = useQueryClient();
  const scheduler = useSkejScheduling(ownerDid, actorDid, { includeSchedules: false });
  const [mode, setMode] = useState<"now" | "schedule">("now");
  const [scheduledAt, setScheduledAt] = useState("");
  const [pending, setPending] = useState(false);
  const locked = useRef(false);
  const key = ["brandAccounts", ownerDid, actorDid, connection.generation] as const;
  const catalog = useQuery({ queryKey: [...key, "catalog"], enabled: !!connection.session, queryFn: async ({ signal }) => { connection.assertCurrentActor(); const data = await getBlueskySocialCatalog(connection.session!, signal, { includeFeeds: false }); connection.assertCurrentActor(); return data; }, retry: false });
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === actorDid ? catalog.data.moderation : undefined;
  const profile = useQuery({ queryKey: [...key, "profile"], enabled: !!connection.session && !!moderation, queryFn: async ({ signal }) => { connection.assertCurrentActor(); const { data } = await createAuthenticatedAppViewAgent(connection.session!).app.bsky.actor.getProfile({ actor: actorDid }, { signal }); connection.assertCurrentActor(); if (data.did !== actorDid) throw new Error("Account Identity Does Not Match."); return data; }, retry: false });
  async function publish(text: string) {
    if (locked.current) throw new Error("Wait For the Current Post.");
    connection.assertCurrentActor();
    locked.current = true; setPending(true); onPendingChange(true);
    try { if (mode === "schedule") { const instant = scheduledInstant(scheduledAt); if (!instant || !scheduler.readiness.data?.connected) throw new Error("Scheduling Is Not Ready."); await scheduler.schedule(text, instant); } else await publishBrandPost({ session: connection.session!, text, assertCurrentActor: connection.assertCurrentActor }); connection.assertCurrentActor(); void cache.invalidateQueries({ queryKey: ["brandAccounts", ownerDid, actorDid] }); onPublished(mode === "schedule"); }
    finally { locked.current = false; setPending(false); onPendingChange(false); }
  }
  if (connection.error || catalog.isError || profile.isError) return <div className="space-y-2"><p role="alert" className="text-sm text-destructive">The Selected Brand Account Could Not Be Loaded.</p><Button variant="outline" onClick={() => { connection.retry(); }}>Retry</Button></div>;
  if (!connection.session || !moderation || !profile.data) return <p role="status" className="text-sm text-muted-foreground">Loading Selected Account…</p>;
  return <BrandPostComposer scheduling={{ controls: <><ScheduleTimingControls mode={mode} value={scheduledAt} disabled={pending} onModeChange={setMode} onChange={setScheduledAt} />{mode === "schedule" ? <SchedulingReadiness connected={scheduler.readiness.data?.connected} pending={scheduler.readiness.isPending} failed={scheduler.readiness.isError} connectUrl={scheduler.connectUrl} retry={() => { void scheduler.readiness.refetch(); }} /> : null}</>, submitLabel: mode === "schedule" ? "Schedule Post" : "Post", pendingLabel: mode === "schedule" ? "Scheduling…" : "Publishing…", valid: mode === "now" || !!scheduledInstant(scheduledAt) && !!scheduler.readiness.data?.connected }} inline ownerDid={ownerDid} session={connection.session} moderation={moderation} profile={profile.data} pending={pending} publish={publish} close={close} assertCurrentActor={connection.assertCurrentActor} />;
}
