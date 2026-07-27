"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, ChevronRight, RefreshCw } from "lucide-react";
import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useSidebarBootstrap,
  useSidebarProjection,
} from "@/contexts/PublicationSidebarContext";
import { cn } from "@/lib/utils";

export function MyPublicationsSection() {
  const router = useRouter();
  const { myPublications } = useSidebarProjection();
  const { sidebarListsLoading, refresh } = useSidebarBootstrap();

  return (
    <section
      id="publications"
      className="flex scroll-mt-16 flex-col gap-5 p-4 md:p-6"
      aria-labelledby="publications-heading"
    >
      <header className="flex shrink-0 flex-wrap items-start justify-between gap-3">
        <div className="flex min-w-0 flex-col gap-1">
          <h1
            id="publications-heading"
            className="truncate text-xl font-black tracking-tight text-foreground"
          >
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
            variant="ghost"
            size="sm"
            className="h-8 gap-1.5 rounded-md border-0 bg-transparent shadow-none hover:bg-muted/50"
            onClick={() => router.push("/read")}
          >
            <ArrowLeft className="size-3.5" />
            Reading list
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            className="size-8 rounded-md border-0 bg-transparent shadow-none hover:bg-muted/50"
            title="Refresh publications"
            onClick={() => refresh.mutate()}
            disabled={refresh.isPending}
          >
            <RefreshCw
              className={cn("size-3.5", refresh.isPending ? "animate-spin" : "")}
            />
          </Button>
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
        <div className="mx-auto flex max-w-lg flex-col gap-3 rounded-2xl border border-dashed border-border bg-card/70 p-6 text-sm text-muted-foreground shadow-[var(--soft-elevation)]">
          <p>We look for publications published under your account.</p>
          <p>
            Create a publication on{" "}
            <a
              href="https://leaflet.pub/"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-foreground underline underline-offset-4"
            >
              Leaflet
            </a>
            ,{" "}
            <a
              href="https://offprint.app/"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-foreground underline underline-offset-4"
            >
              Offprint
            </a>
            , or{" "}
            <a
              href="https://pckt.blog/"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-foreground underline underline-offset-4"
            >
              pckt
            </a>
            .
          </p>
        </div>
      ) : (
        <ul className="mx-auto flex w-full max-w-2xl flex-col gap-2">
          {myPublications.map((pub) => (
            <li key={pub.publicationId}>
              <Link
                href={`/read/${encodeURIComponent(pub.publicationId)}`}
                className="flex min-h-16 items-center gap-3 rounded-2xl border border-border/80 bg-card/88 px-3 py-2 text-card-foreground shadow-[var(--soft-elevation)] transition-[border-color,background-color,box-shadow] hover:border-border hover:bg-muted/45 hover:shadow-md"
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
    </section>
  );
}
