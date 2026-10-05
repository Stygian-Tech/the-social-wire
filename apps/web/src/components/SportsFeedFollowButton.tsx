"use client";

import { useState } from "react";
import { Check, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { SportsPublicInterestDialog } from "@/components/SportsPublicInterestDialog";
import { acknowledgeSportsPublicInterests, readSportsPublicInterestConsent } from "@/lib/sportsPublicInterestConsent";
import type { SportsEntity, SportsSelection } from "@/lib/sportsFeedClient";

export function SportsFeedFollowButton({ entity, selections, save, saving, loading, signedIn, viewerDID }: {
  entity?: SportsEntity;
  selections: SportsSelection[];
  save: (args: { selection: SportsSelection; remove: boolean }) => Promise<unknown>;
  saving: boolean;
  loading: boolean;
  signedIn: boolean;
  viewerDID?: string;
}) {
  const [confirmation, setConfirmation] = useState<{ viewer: string; reference: string } | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!entity?.active) return null;
  const previous = selections.find(selection => selection.reference === entity.id);
  const following = previous?.action === "follow";
  const disabled = !signedIn || !viewerDID || loading || saving || pending || following;
  const follow = async () => {
    if (disabled) return;
    setPending(true);
    setError(null);
    const now = new Date().toISOString();
    try {
      await save({ selection: { reference: entity.id, action: "follow", createdAt: previous?.createdAt ?? now, updatedAt: now }, remove: false });
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : "Could not follow this feed. Try again.");
    } finally {
      setPending(false);
    }
  };
  const confirmationOpen = confirmation?.viewer === viewerDID && confirmation?.reference === entity.id && signedIn;
  return <>
    <Button variant={following ? "secondary" : "outline"} disabled={disabled} aria-pressed={following}
      title={!signedIn ? "Sign In to Follow This Feed" : following ? "Manage This Interest in Customize" : undefined}
      onClick={() => {
        if (disabled) return;
        if (readSportsPublicInterestConsent(viewerDID)) void follow();
        else setConfirmation({ viewer: viewerDID!, reference: entity.id });
      }}>
      {following ? <Check aria-hidden="true" /> : <Plus aria-hidden="true" />}
      {pending || saving ? "Saving…" : following ? "Following" : "Follow"}
    </Button>
    {error ? <span role="alert" className="text-sm text-destructive">{error}</span> : null}
    <SportsPublicInterestDialog open={confirmationOpen} onCancel={() => setConfirmation(null)} onAccept={() => {
      if (!confirmationOpen || disabled) return;
      acknowledgeSportsPublicInterests(viewerDID);
      setConfirmation(null);
      void follow();
    }} />
  </>;
}
