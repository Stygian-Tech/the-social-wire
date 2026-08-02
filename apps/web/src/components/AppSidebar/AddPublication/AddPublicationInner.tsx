"use client";

import Link from "next/link";
import { useId, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Button, buttonVariants } from "@/components/ui/button";
import { DialogClose, DialogFooter } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/useAuth";
import {
  useAddPublicationFromAnyLink,
  useResolvePublicationForAdd,
} from "@/hooks/usePublications";
import { usePDSClient } from "@/hooks/usePDSClient";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import {
  addPublicationSubmitAction,
  type ResolvedPublicationSearch,
} from "@/lib/addPublicationFlow";
import {
  looksLikeOAuthScopeOrSessionError,
  looksLikeStaleOAuthStorageError,
} from "@/lib/oauthSessionSignals";
import { Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";
import { PublicationAuthFields } from "./PublicationAuthFields";

export interface AddPublicationInnerProps {
  onCloseRequest: () => void;
}

export function AddPublicationInner({ onCloseRequest }: AddPublicationInnerProps) {
  const labelId = useId();
  const linkId = `${labelId}-link`;
  const titleId = `${labelId}-title`;
  const router = useRouter();
  const { session, isLoading: authLoading, reconcileOAuthSession } = useAuth();
  const client = usePDSClient();

  const [link, setLink] = useState("");
  const [title, setTitle] = useState("");
  const [resolved, setResolved] = useState<ResolvedPublicationSearch | null>(null);
  const [finishing, setFinishing] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [showScopeReconnect, setShowScopeReconnect] = useState(false);

  const addPublication = useAddPublicationFromAnyLink();
  const resolvePublication = useResolvePublicationForAdd();

  const { data: profile } = useViewerProfile();
  const authorizeSeedHandle = useMemo(() => {
    const h = profile?.handle?.trim();
    return h && !h.startsWith("did:") ? h : "";
  }, [profile?.handle]);

  const oauthReady = !!client;
  const signedOut = !session?.did && !authLoading;
  const sessionPendingOAuth = !!session?.did && !oauthReady && !authLoading;

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!link.trim() || finishing) return;
    setSubmitError(null);
    setShowScopeReconnect(false);

    setFinishing(true);
    try {
      const action = addPublicationSubmitAction({ input: link, resolved });
      if (action.kind === "resolve") {
        const publication = await resolvePublication.mutateAsync(action.input);
        setResolved({ input: action.input, publication });
        return;
      }
      const result = await addPublication.mutateAsync({
        link: action.input,
        title: title.trim() || undefined,
        resolved: action.publication,
      });
      onCloseRequest();
      router.push(`/read/${encodeURIComponent(result.navigatePubId)}`);
    } catch (err) {
      console.error(err);
      if (looksLikeStaleOAuthStorageError(err)) {
        try {
          const restored = await reconcileOAuthSession();
          if (restored) {
            setShowScopeReconnect(false);
            setSubmitError(
              "Your browser session was out of sync; we refreshed it from storage. Tap Add again to finish."
            );
            return;
          }
        } catch (reconcileErr) {
          console.error(reconcileErr);
        }
        setShowScopeReconnect(true);
        setSubmitError(
          "This browser lost its ATProto OAuth session (common with multiple tabs or a dev reload). Sign in below to reconnect."
        );
        return;
      }
      if (looksLikeOAuthScopeOrSessionError(err)) {
        setShowScopeReconnect(true);
        setSubmitError(
          "Authorization issue — sign in again so we can save publication or RSS subscriptions on your PDS."
        );
      } else {
        setSubmitError(
          err instanceof Error ? err.message : "Something went wrong. Try again."
        );
      }
    } finally {
      setFinishing(false);
    }
  }

  const pending =
    finishing || addPublication.isPending || resolvePublication.isPending;
  const resolvedPublication =
    resolved?.input === link.trim() ? resolved.publication : null;

  return (
    <>
      {authLoading ? (
        <div className="space-y-4 py-2">
          <div
            className="flex flex-col items-center gap-3 py-4 text-center text-sm text-muted-foreground"
            role="status"
          >
            <Loader2 className="h-8 w-8 animate-spin opacity-70" aria-hidden />
            Checking Your ATProto Session…
          </div>
          <div className="flex justify-end">
            <DialogClose render={<Button type="button" variant="outline" />}>
              Cancel
            </DialogClose>
          </div>
        </div>
      ) : signedOut ? (
        <div className="space-y-4 py-2">
          <p className="text-sm text-muted-foreground">
            Sign in to create standard.site graph subscriptions or RSS-backed publications on your
            PDS.
          </p>
          <div className="flex flex-wrap gap-2">
            <Link href="/login" className={cn(buttonVariants({ variant: "default" }))}>
              Sign In To Continue
            </Link>
            <DialogClose render={<Button type="button" variant="outline" />}>
              Cancel
            </DialogClose>
          </div>
        </div>
      ) : sessionPendingOAuth ? (
        <PublicationAuthFields
          key={authorizeSeedHandle ? `oauth:${authorizeSeedHandle}` : "oauth-pending"}
          idPrefix={labelId}
          seedHandle={authorizeSeedHandle}
          lead={
            <p>
              Your account is remembered, but this browser does not have an active OAuth session.
              Authorize below to add publications from links.
            </p>
          }
        />
      ) : (
        <>
          {showScopeReconnect ? (
            <div className="rounded-md border border-border bg-muted/40 p-3">
              <p className="text-sm font-medium text-foreground">Subscription Scopes</p>
              <p className="mt-1 text-xs text-muted-foreground">
                If you joined before this feature, sign in again to include{" "}
                <code className="text-[10px]">site.standard.graph.subscription</code> and{" "}
                <code className="text-[10px]">app.skyreader.feed.subscription</code>.
              </p>
              <div className="mt-3">
                <PublicationAuthFields
                  key={
                    authorizeSeedHandle
                      ? `reauth:${authorizeSeedHandle}`
                      : "reauth-pending"
                  }
                  idPrefix={`${labelId}-re`}
                  seedHandle={authorizeSeedHandle}
                  lead={null}
                />
              </div>
            </div>
          ) : null}
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor={linkId}>Publication Link</Label>
              <Input
                id={linkId}
                placeholder="https://a.blog/about, alice.bsky.social, or publication AT-URI"
                value={link}
                onChange={(event) => {
                  setLink(event.target.value);
                  setResolved(null);
                  setSubmitError(null);
                }}
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                autoFocus={!showScopeReconnect}
                required
              />
            </div>
            {resolvedPublication ? (
              <div className="rounded-lg border bg-muted/35 p-3" role="status">
                <p className="text-sm font-medium text-foreground">
                  {resolvedPublication.kind === "standard-site"
                    ? "standard.site Publication Found"
                    : "RSS Feed Found"}
                </p>
                <p className="mt-1 break-all text-xs text-muted-foreground">
                  {resolvedPublication.kind === "standard-site"
                    ? resolvedPublication.publicationAtUri
                    : resolvedPublication.title || resolvedPublication.feedUrl}
                </p>
                {resolvedPublication.kind === "rss" &&
                resolvedPublication.title ? (
                  <p className="mt-1 break-all text-[11px] text-muted-foreground/80">
                    {resolvedPublication.feedUrl}
                  </p>
                ) : null}
              </div>
            ) : null}
            <div className="space-y-1.5">
              <Label htmlFor={titleId}>Title (Optional)</Label>
              <Input
                id={titleId}
                placeholder="Override sidebar label — mainly used for RSS feeds"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
              />
            </div>
            {submitError ? (
              <p className="text-sm text-destructive" role="alert">
                {submitError}
              </p>
            ) : null}
            <DialogFooter>
              <DialogClose
                disabled={pending}
                render={<Button type="button" variant="outline" disabled={pending} />}
              >
                Cancel
              </DialogClose>
              <button
                type="submit"
                disabled={!link.trim() || pending}
                className={cn(buttonVariants())}
              >
                {resolvePublication.isPending
                  ? "Finding…"
                  : addPublication.isPending
                    ? "Adding…"
                    : resolvedPublication
                      ? "Add Publication"
                      : "Find Publication"}
              </button>
            </DialogFooter>
          </form>
        </>
      )}
    </>
  );
}
