"use client";

import Link from "next/link";
import {
  type FormEvent,
  type ReactNode,
  useCallback,
  useId,
  useMemo,
  useState,
} from "react";
import { useRouter } from "next/navigation";
import { Button, buttonVariants } from "@/components/ui/button";
import { SIDEBAR_GLASS_ROW_ACTION } from "@/components/ui/sidebar";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/useAuth";
import { useAddPublicationFromAnyLink } from "@/hooks/usePublications";
import { usePDSClient } from "@/hooks/usePDSClient";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import {
  looksLikeOAuthScopeOrSessionError,
  looksLikeStaleOAuthStorageError,
} from "@/lib/oauthSessionSignals";
import { CirclePlus, Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";

export function AddPublicationDialog() {
  const [open, setOpen] = useState(false);
  const [formKey, setFormKey] = useState(0);
  const descriptionId = `${useId()}-add-pub-desc`;

  const handleOpenChange = useCallback((next: boolean) => {
    setOpen(next);
    if (next) setFormKey((k) => k + 1);
  }, []);

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger
        render={
          <Button
            variant="ghost"
            className={cn(SIDEBAR_GLASS_ROW_ACTION)}
          />
        }
      >
        <CirclePlus className="h-4 w-4 shrink-0" />
        Add Publication
      </DialogTrigger>
      <DialogContent aria-describedby={descriptionId}>
        <DialogHeader>
          <DialogTitle>Add Publication</DialogTitle>
          <DialogDescription id={descriptionId}>
            Paste any link, a Bluesky handle, a DID, or a publication AT-URI. We look for{" "}
            <code className="text-[10px]">/.well-known/site.standard.publication</code> first, then try
            RSS/Atom and save a Skyreader-compatible feed subscription if needed (
            <code className="text-[10px]">app.skyreader.feed.subscription</code>) on your PDS.
          </DialogDescription>
        </DialogHeader>
        <AddPublicationInner key={formKey} onCloseRequest={() => handleOpenChange(false)} />
      </DialogContent>
    </Dialog>
  );
}

interface AddPublicationInnerProps {
  onCloseRequest: () => void;
}

interface PublicationAuthFieldsProps {
  idPrefix: string;
  lead: ReactNode | null;
  seedHandle: string;
}

function PublicationAuthFields({ idPrefix, lead, seedHandle }: PublicationAuthFieldsProps) {
  const { signIn } = useAuth();
  const handleId = `${idPrefix}-authorize-handle`;

  const [handle, setHandle] = useState(seedHandle);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    const h = handle.trim();
    if (!h) {
      setError("Enter your handle to continue.");
      return;
    }
    setBusy(true);
    try {
      await signIn(h);
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Authorization failed. Try again."
      );
      setBusy(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      {lead ? (
        <div className="space-y-2 text-sm text-muted-foreground">{lead}</div>
      ) : null}
      <div className="space-y-1.5">
        <Label htmlFor={handleId}>Bluesky or ATProto handle</Label>
        <Input
          id={handleId}
          type="text"
          name="publication-authorize-handle"
          autoCapitalize="none"
          autoCorrect="off"
          autoComplete="username"
          spellCheck={false}
          placeholder="you.bsky.social"
          value={handle}
          onChange={(ev) => setHandle(ev.target.value)}
          disabled={busy}
          required
        />
      </div>
      {error ? (
        <p className="text-sm text-destructive" role="alert">
          {error}
        </p>
      ) : null}
      <DialogFooter className="gap-2 sm:gap-0">
        <DialogClose
          disabled={busy}
          render={<Button type="button" variant="outline" disabled={busy} />}
        >
          Cancel
        </DialogClose>
        <Button type="submit" disabled={busy || !handle.trim()}>
          {busy ? (
            <>
              <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden />
              Redirecting…
            </>
          ) : (
            "Authorize Publication Subscriptions"
          )}
        </Button>
      </DialogFooter>
      <p className="text-xs text-muted-foreground">
        Signing in grants repository access including{" "}
        <code className="text-[10px]">site.standard.graph.subscription</code> and{" "}
        <code className="text-[10px]">app.skyreader.feed.subscription</code>.
      </p>
    </form>
  );
}

function AddPublicationInner({ onCloseRequest }: AddPublicationInnerProps) {
  const labelId = useId();
  const linkId = `${labelId}-link`;
  const titleId = `${labelId}-title`;
  const router = useRouter();
  const { session, isLoading: authLoading, reconcileOAuthSession } = useAuth();
  const client = usePDSClient();

  const [link, setLink] = useState("");
  const [title, setTitle] = useState("");
  const [finishing, setFinishing] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [showScopeReconnect, setShowScopeReconnect] = useState(false);

  const addPublication = useAddPublicationFromAnyLink();

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
      const result = await addPublication.mutateAsync({
        link: link.trim(),
        title: title.trim() || undefined,
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

  const pending = finishing || addPublication.isPending;

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
              <Label htmlFor={linkId}>Link</Label>
              <Input
                id={linkId}
                type="text"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                placeholder="https://a.blog/about, alice.bsky.social, or publication AT-URI"
                value={link}
                onChange={(e) => setLink(e.target.value)}
                autoFocus={!showScopeReconnect}
                required
              />
            </div>
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
                {pending ? "Adding…" : "Add"}
              </button>
            </DialogFooter>
          </form>
        </>
      )}
    </>
  );
}
