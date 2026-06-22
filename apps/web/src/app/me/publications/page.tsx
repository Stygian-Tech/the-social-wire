"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, ChevronRight, RefreshCw } from "lucide-react";
import { AddPublicationDialog } from "@/components/AppSidebar/AddPublicationDialog";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useSidebarBootstrap,
  useSidebarProjection,
} from "@/contexts/PublicationSidebarContext";
import { cn } from "@/lib/utils";

export default function MyPublicationsPage() {
  const router = useRouter();
  const { myPublications } = useSidebarProjection();
  const { sidebarListsLoading, refresh } = useSidebarBootstrap();

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto overscroll-y-contain p-4 md:p-6">
      <header className="flex shrink-0 flex-wrap items-start justify-between gap-3">
        <div className="flex min-w-0 flex-col gap-1">
          <h1 className="truncate text-xl font-black tracking-tight text-[var(--purple-foreground)]">
            My Publications
          </h1>
          <p className="text-sm text-muted-foreground">
            Publications we attribute to your account. Open one to continue in the
            reader.
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap items-center gap-2">
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="gap-1.5"
            onClick={() => router.push("/read")}
          >
            <ArrowLeft className="size-3.5" />
            Reading list
          </Button>
          <Button
            type="button"
            variant="outline"
            size="icon-sm"
            className="size-9"
            title="Refresh publications"
            onClick={() => refresh.mutate()}
            disabled={refresh.isPending}
          >
            <RefreshCw
              className={cn("size-3.5", refresh.isPending ? "animate-spin" : "")}
            />
          </Button>
          <div className="inline-flex shrink-0 [&_button]:w-auto [&_button]:justify-start">
            <AddPublicationDialog />
          </div>
        </div>
      </header>

      {sidebarListsLoading ? (
        <ul className="mx-auto flex w-full max-w-2xl flex-col gap-2" aria-busy="true">
          {Array.from({ length: 5 }).map((_, i) => (
            <li key={i}>
              <Skeleton className="h-16 w-full rounded-2xl border border-border/50" />
            </li>
          ))}
        </ul>
      ) : myPublications.length === 0 ? (
        <div className="mx-auto flex max-w-lg flex-col gap-3 rounded-2xl border border-dashed border-[var(--purple-border)] bg-card/70 p-6 text-sm text-muted-foreground shadow-[var(--soft-elevation)]">
          <p>
            Nothing here yet—we look for publications published under your DID (Standard
            Site discovery and related sources). Use{" "}
            <span className="font-medium text-foreground">Add Publication</span> above to
            add one.
          </p>
        </div>
      ) : (
        <ul className="mx-auto flex w-full max-w-2xl flex-col gap-2">
          {myPublications.map((pub) => (
            <li key={pub.publicationId}>
              <Link
                href={`/read/${encodeURIComponent(pub.publicationId)}`}
                className="flex min-h-16 items-center gap-3 rounded-2xl border border-border/80 bg-card/88 px-3 py-2 text-card-foreground shadow-[var(--soft-elevation)] transition-[border-color,background-color,box-shadow] hover:border-[var(--purple-border)] hover:bg-accent/45 hover:[box-shadow:var(--purple-glow-hover)]"
              >
                <Avatar
                  src={pub.iconUrl ?? pub.avatarUrl}
                  alt=""
                  size={40}
                  className="shrink-0 rounded-md"
                />
                <div className="min-w-0 flex-1 py-0.5">
                  <p className="truncate text-sm font-medium leading-snug">
                    {pub.title}
                  </p>
                  {pub.subscriptionPublicationId &&
                  pub.subscriptionPublicationId !== pub.publicationId ? (
                    <p className="truncate text-[11px] text-muted-foreground">
                      {pub.subscriptionPublicationId}
                    </p>
                  ) : null}
                </div>
                <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden />
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
