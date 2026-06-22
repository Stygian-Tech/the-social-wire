"use client";

import { useState, FormEvent } from "react";
import Image from "next/image";
import { useAuth } from "@/hooks/useAuth";
import iconSrc from "@/app/icon.png";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export default function LoginPage() {
  const { signIn } = useAuth();
  const [handle, setHandle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isPending, setIsPending] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setIsPending(true);
    try {
      await signIn(handle.trim());
      // signIn redirects to PDS; if it returns, something is wrong
    } catch (err) {
      setError(err instanceof Error ? err.message : "Sign-in failed. Check your handle and try again.");
      setIsPending(false);
    }
  }

  return (
    <div className="flex min-h-[calc(100svh-var(--environment-banner-height,0px))] flex-1 items-center justify-center bg-background p-4">
      <div className="flex w-full max-w-sm flex-col gap-8 rounded-3xl border border-border/80 bg-card/88 p-5 shadow-[var(--soft-elevation)] backdrop-blur-md sm:p-6">
        <div className="text-center">
          <div className="mb-4 flex justify-center">
            <Image
              src={iconSrc}
              alt=""
              width={56}
              height={56}
              className="rounded-2xl shadow-[0_10px_28px_-18px_var(--primary)]"
              priority
            />
          </div>
          <h1 className="text-2xl font-black tracking-tight text-[var(--purple-foreground)]">The Social Wire</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Sign in with your Bluesky or ATProto account
          </p>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-2">
            <label
              htmlFor="handle"
              className="text-sm font-medium leading-none"
            >
              Handle
            </label>
            <Input
              id="handle"
              type="text"
              value={handle}
              onChange={(e) => setHandle(e.target.value)}
              placeholder="you.bsky.social"
              autoCapitalize="none"
              autoCorrect="off"
              autoComplete="username"
              spellCheck={false}
              required
              disabled={isPending}
              className="h-11"
            />
          </div>

          {error && (
            <p className="text-sm text-destructive">{error}</p>
          )}

          <Button
            type="submit"
            disabled={isPending || !handle.trim()}
            className="h-11 w-full"
          >
            {isPending ? "Signing In…" : "Continue with ATProto"}
          </Button>
        </form>

        <p className="text-center text-xs text-muted-foreground">
          Your reading preferences are stored on your own PDS,
          not on our servers.
        </p>
      </div>
    </div>
  );
}
