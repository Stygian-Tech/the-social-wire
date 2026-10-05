import { notFound } from "next/navigation";
import { podcastsEnabled } from "@/lib/podcasts/playback";
import { PodcastLibrary } from "@/components/Podcasts/PodcastLibrary";
export default function PodcastsPage() {
  if (!podcastsEnabled()) notFound();
  return <PodcastLibrary />;
}
