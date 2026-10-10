import Image from "next/image";
import Link from "next/link";
import {
  Archive,
  ArrowRight,
  Bookmark,
  CheckCircle2,
  FolderOpen,
  Headphones,
  List,
  Newspaper,
  Rss,
} from "lucide-react";
import iconSrc from "@/app/icon.png";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { podcastsEnabled } from "@/lib/podcasts/playback";

const workflowItems = [
  {
    title: "Follow Publications",
    description:
      "Keep standard.site, RSS, and social-web writing together in one calm reading surface.",
    icon: Rss,
  },
  {
    title: "Read Later",
    description:
      "Save links, archive finished reads, and keep the article view focused on the text.",
    icon: Bookmark,
  },
  {
    title: "Stay Organized",
    description:
      "Group publications into folders, track unread posts, and keep your reading organized.",
    icon: FolderOpen,
  },
  {
    title: "Topics",
    description:
      "Follow Finance and Sports news around the markets, teams, and leagues you care about.",
    icon: Newspaper,
  },
  {
    title: "Lists",
    description:
      "Create or follow lists of publications and creators, and keep their writing together.",
    icon: List,
  },
];

export default function Home() {
  const listeningEnabled = podcastsEnabled();
  const features = [...workflowItems, {
    title: "Podcasts",
    description: listeningEnabled
      ? "Listen to RSS and AT Protocol podcasts with chapters, transcripts, playback controls, and offline downloads."
      : "Podcast listening is in development, with RSS and AT Protocol subscriptions, chapters, transcripts, and offline downloads.",
    icon: Headphones,
  }];
  return (
    <main className="min-h-[calc(100svh-var(--environment-banner-height,0px))] overflow-hidden text-foreground">
      <section className="relative flex min-h-[min(760px,calc(100svh-var(--environment-banner-height,0px)))] flex-col">
        <Image
          src="/og/the-social-wire.png"
          alt=""
          fill
          priority
          sizes="100vw"
          className="absolute inset-0 -z-20 object-cover object-center opacity-35"
        />
        <div className="absolute inset-0 -z-10 bg-background/70" />

        <header className="mx-auto flex w-full max-w-6xl items-center justify-between gap-3 px-4 py-4 sm:px-6 lg:px-8">
          <Link href="/" className="flex min-w-0 items-center gap-3">
            <Image
              src={iconSrc}
              alt=""
              width={44}
              height={44}
              className="shrink-0 rounded-2xl shadow-[0_12px_28px_-18px_var(--primary)]"
            />
            <span className="truncate text-base font-black text-foreground">
              The Social Wire
            </span>
          </Link>
          <div className="flex shrink-0 items-center gap-2">
            <Link
              href="/login"
              className={buttonVariants({
                variant: "outline",
                size: "sm",
              })}
            >
              Sign In
            </Link>
            <Link
              href="/read"
              className={buttonVariants({
                variant: "default",
                size: "sm",
                className: "max-sm:hidden",
              })}
            >
              Start Reading
              <ArrowRight data-icon="inline-end" />
            </Link>
          </div>
        </header>

        <div className="mx-auto flex w-full max-w-6xl flex-1 flex-col justify-center px-4 pb-16 pt-10 sm:px-6 lg:px-8">
          <div className="max-w-2xl">
            <h1 className="text-5xl font-black leading-[0.95] tracking-tight text-foreground sm:text-6xl lg:text-7xl">
              The Social Wire
            </h1>
            <p className="mt-5 max-w-xl text-lg font-semibold leading-8 text-foreground/78 sm:text-xl">
              {listeningEnabled
                ? "Your home for reading and listening across publications, topics, lists, and podcasts."
                : "Your home for publications, saved links, topics, and lists on the open social web. Podcast listening is in development."}
            </p>
            <div className="mt-7 flex flex-col gap-3 sm:flex-row">
              <Link
                href="/read"
                className={buttonVariants({
                  variant: "default",
                  size: "lg",
                  className: "h-12",
                })}
              >
                Start Reading
                <ArrowRight data-icon="inline-end" />
              </Link>
              <Link
                href={listeningEnabled ? "/podcasts" : "/login"}
                className={buttonVariants({
                  variant: "outline",
                  size: "lg",
                  className: "h-12",
                })}
              >
                {listeningEnabled ? "Start Listening" : "Continue with ATProto"}
              </Link>
            </div>
          </div>
        </div>
      </section>

      <section className="border-t bg-background/82 px-4 py-10 backdrop-blur-md sm:px-6 lg:px-8">
        <div className="mx-auto grid w-full max-w-6xl gap-4 md:grid-cols-3">
          {features.map((item) => {
            const Icon = item.icon;
            return (
              <article
                key={item.title}
                className="rounded-2xl border border-border/80 bg-card/88 p-5 shadow-[var(--soft-elevation)]"
              >
                <div className="mb-4 grid size-11 place-items-center rounded-2xl bg-primary text-primary-foreground shadow-[0_12px_28px_-18px_var(--primary)]">
                  <Icon aria-hidden className="size-5" />
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="text-lg font-black tracking-tight">{item.title}</h2>
                  {item.title === "Podcasts" && !listeningEnabled ? (
                    <span className="rounded-full border bg-muted px-2 py-1 text-xs font-semibold text-muted-foreground">In Development</span>
                  ) : null}
                </div>
                <p className="mt-2 text-sm font-medium leading-6 text-muted-foreground">
                  {item.description}
                </p>
                {item.title === "Podcasts" && listeningEnabled ? (
                  <Link href="/podcasts" className="mt-3 inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-primary hover:underline">
                    Explore Podcasts <ArrowRight aria-hidden className="size-4" />
                  </Link>
                ) : null}
              </article>
            );
          })}
        </div>
      </section>

      <section className="px-4 pb-12 sm:px-6 lg:px-8">
        <div className="mx-auto flex w-full max-w-6xl flex-col gap-4 rounded-3xl border border-border/80 bg-card/88 p-5 shadow-[var(--soft-elevation)] sm:flex-row sm:items-center sm:justify-between">
          <div className="flex min-w-0 items-start gap-3">
            <div className="grid size-10 shrink-0 place-items-center rounded-2xl bg-primary/10 text-[var(--purple-foreground)]">
              <CheckCircle2 aria-hidden className="size-5" />
            </div>
            <div className="min-w-0">
              <h2 className="text-xl font-black tracking-tight">
                {listeningEnabled ? "Built for Reading and Listening." : "Built for Everyday Reading."}
              </h2>
              <p className="mt-1 text-sm font-medium leading-6 text-muted-foreground">
                {listeningEnabled
                  ? "Read a publication, explore a topic, follow a list, or pick up your next podcast episode."
                  : "Read a publication, explore a topic, follow a list, or return to your saved links."}
              </p>
            </div>
          </div>
          <div className="grid grid-cols-2 gap-2 sm:flex">
            <Link
              href="/saved"
              className={cn(
                buttonVariants({ variant: "outline", size: "sm" }),
                "min-w-0"
              )}
            >
              <Bookmark data-icon="inline-start" />
              Saved
            </Link>
            <Link
              href="/archive"
              className={cn(
                buttonVariants({ variant: "outline", size: "sm" }),
                "min-w-0"
              )}
            >
              <Archive data-icon="inline-start" />
              Archive
            </Link>
          </div>
        </div>
      </section>
    </main>
  );
}
