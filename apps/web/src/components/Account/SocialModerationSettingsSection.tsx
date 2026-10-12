"use client";

import { useState } from "react";
import { moderateProfile } from "@atproto/api";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { useSocialModerationSettings } from "@/hooks/useSocialModerationSettings";
import { localizedSocialLabel, socialLabelVisibility } from "@/lib/socialModerationClient";

export function SocialModerationSettingsSection() {
  const { session } = useAuth();
  const [open, setOpen] = useState(false);
  return <section aria-labelledby="social-moderation-heading" className="border-t p-4 md:p-6">
    <div className="mx-auto flex max-w-2xl flex-col gap-3">
      <h2 id="social-moderation-heading" className="text-sm font-bold">Social Moderation</h2>
      <p className="text-sm text-muted-foreground">Choose labelers and how their labels appear in Social.</p>
      <Button className="self-start" variant="outline" disabled={!session} aria-expanded={open} onClick={() => setOpen(value => !value)}>{open ? "Close Moderation Settings" : "Manage Labelers"}</Button>
      {open && session ? <SocialModerationControls key={session.did} /> : null}
    </div>
  </section>;
}

function SocialModerationControls() {
  const { settings, lookup, change } = useSocialModerationSettings();
  const [actor, setActor] = useState("");
  const [removing, setRemoving] = useState<string>();
  const busy = change.isPending;
  const data = !settings.isError ? settings.data : undefined;
  const error = change.error ?? lookup.error ?? settings.error;
  const languages = typeof navigator === "undefined" ? ["en"] : navigator.languages;
  const displayName = (profile: NonNullable<typeof data>["labelers"][number]["profile"]) => {
    if (!data) return profile.did;
    const decision = moderateProfile(profile, data.moderation);
    return (["profileList", "displayName"] as const).some(context => {
      const ui = decision.ui(context); return ui.filter || ui.blur || ui.noOverride;
    }) ? profile.did : profile.displayName || `@${profile.handle}`;
  };
  return <div className="flex flex-col gap-4">
    {settings.isPending ? <p role="status">Loading Labelers…</p> : null}
    {error ? <p role="alert">{error instanceof Error ? error.message : "Could not update moderation settings."}</p> : null}
    {settings.isError ? <Button variant="outline" onClick={() => { void settings.refetch(); }}>Retry</Button> : null}
    {data ? <>
      <h3 className="text-sm font-semibold">Active Labelers</h3>
      {!data.labelers.length ? <p className="text-sm text-muted-foreground">No Active Labelers</p> : null}
      {data.labelers.map(labeler => <div key={labeler.did} className="flex flex-col gap-3 rounded-xl border p-3">
        <div className="flex flex-wrap items-center gap-2"><h4 className="min-w-0 break-words font-medium">{displayName(labeler.profile)}</h4>
          {labeler.mandatory ? <span className="text-xs text-muted-foreground">Required</span> : <Button variant="outline" disabled={busy} onClick={() => setRemoving(labeler.did)}>Remove Labeler</Button>}
        </div>
        {!labeler.definitions.length ? <p className="text-sm text-muted-foreground">This Labeler Has No Configurable Labels.</p> : null}
        {labeler.definitions.map(definition => {
          const localized = localizedSocialLabel(definition, languages);
          const current = socialLabelVisibility(definition, data.moderation);
          return <fieldset key={definition.identifier} disabled={busy || current.disabled} className="flex flex-col gap-1">
            <legend className="text-sm font-medium">{localized.name}</legend>
            {localized.description ? <p className="text-xs text-muted-foreground">{localized.description}</p> : null}
            <div className="flex flex-wrap gap-1">{(["ignore", "warn", "hide"] as const).map((visibility, index) => <Button key={visibility} size="sm" variant={current.visibility === visibility ? "default" : "outline"} aria-pressed={current.visibility === visibility} onClick={() => change.mutate({ type: "label", did: labeler.did, label: definition.identifier, visibility })}>{["Show", "Warn", "Hide"][index]}</Button>)}</div>
            {current.disabled ? <p className="text-xs text-muted-foreground">{definition.flags.includes("adult") && !data.moderation.prefs.adultContentEnabled ? "Adult Content Is Disabled." : "This Label Cannot Be Changed."}</p> : null}
          </fieldset>;
        })}
      </div>)}
      {removing ? <div role="group" aria-label="Confirm Labeler Removal" className="rounded-xl border p-3 text-sm">
        <p>Remove This Labeler?</p><div className="mt-2 flex gap-2"><Button variant="outline" disabled={busy} onClick={() => setRemoving(undefined)}>Cancel</Button><Button variant="destructive" disabled={busy} onClick={() => { change.mutate({ type: "unsubscribe", did: removing }, { onSuccess: () => setRemoving(undefined) }); }}>Confirm Removal</Button></div>
      </div> : null}
      <form className="flex flex-col gap-2" onSubmit={event => { event.preventDefault(); lookup.mutate(actor); }}>
        <label htmlFor="social-labeler-search" className="text-sm font-semibold">Add Labeler</label>
        <input id="social-labeler-search" value={actor} onChange={event => { setActor(event.target.value); lookup.reset(); }} placeholder="Handle or DID" className="rounded-md border bg-background px-3 py-2 text-sm" autoCapitalize="none" autoCorrect="off" />
        <Button className="self-start" variant="outline" type="submit" disabled={!actor.trim() || lookup.isPending || busy}>Find Labeler</Button>
      </form>
      {lookup.data ? <div className="flex flex-wrap items-center gap-2"><span className="min-w-0 break-words text-sm">{displayName(lookup.data.profile)}</span><Button disabled={busy || data.labelers.some(item => item.did === lookup.data.did)} onClick={() => change.mutate({ type: "subscribe", did: lookup.data.did }, { onSuccess: () => { lookup.reset(); setActor(""); } })}>Subscribe</Button></div> : null}
    </> : null}
  </div>;
}
