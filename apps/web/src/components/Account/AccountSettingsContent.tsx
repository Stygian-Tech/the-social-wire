"use client";

import { useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import { podcastsEnabled } from "@/lib/podcasts/playback";
import { useOptionalPodcastPlayer } from "@/components/Podcasts/PodcastPlayerProvider";
import { PodcastPlaybackDefaults } from "@/components/Podcasts/PodcastPlaybackDefaults";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { FeedSettingsSection } from "./FeedSettingsSection";
import { OpmlImportSection } from "./OpmlImportSection";

export function AccountSettingsContent() {
  const { session, signOut } = useAuth();
  const profile = useViewerProfile();
  const player = useOptionalPodcastPlayer();
  const [confirming, setConfirming] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const handle = profile.data?.handle;

  const logOut = async () => {
    setSigningOut(true);
    setError(null);
    try {
      await signOut();
      setConfirming(false);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not log out. Try again.");
    } finally {
      setSigningOut(false);
    }
  };

  return <div className="flex flex-col">
    <section aria-labelledby="account-settings-heading" className="p-4 md:p-6">
      <div className="mx-auto flex max-w-2xl flex-col gap-3">
        <h2 id="account-settings-heading" className="text-sm font-bold">Account</h2>
        <p className="break-all text-sm text-muted-foreground">{handle ? (handle.startsWith("did:") ? handle : `@${handle}`) : session?.did}</p>
        <Button variant="outline" className="self-start" disabled={!session || signingOut} onClick={() => { setError(null); setConfirming(true); }}>Log Out</Button>
      </div>
    </section>
    <FeedSettingsSection />
    {podcastsEnabled() && player ? <section aria-labelledby="podcast-settings-heading" className="border-t p-4 md:p-6">
      <div className="mx-auto flex max-w-2xl flex-col gap-3">
        <h2 id="podcast-settings-heading" className="text-sm font-bold">Podcasts</h2>
        <p className="text-sm text-muted-foreground">Set playback speed and silence removal for all podcasts.</p>
        <div className="self-start"><PodcastPlaybackDefaults player={player} /></div>
        {player.error ? <p role="alert" className="text-sm text-destructive">{player.error}</p> : null}
      </div>
    </section> : null}
    <OpmlImportSection />
    <Dialog open={confirming} onOpenChange={(open) => { if (!signingOut) setConfirming(open); }}>
      <DialogContent showCloseButton={!signingOut}>
        <DialogHeader>
          <DialogTitle>Log Out of The Social Wire?</DialogTitle>
          <DialogDescription>You&apos;ll need to sign in again to see your feeds.</DialogDescription>
        </DialogHeader>
        {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
        <DialogFooter>
          <DialogClose disabled={signingOut} render={<Button variant="outline" />}>Cancel</DialogClose>
          <Button variant="destructive" disabled={signingOut} onClick={() => { void logOut(); }}>{signingOut ? "Logging Out…" : "Log Out"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>;
}
