"use client";

import dynamic from "next/dynamic";
import { use } from "react";
import { readRoutePubIdFromSegments } from "@/lib/atprotoClient";

const ReadPubPage = dynamic(() => import("./ReadPubPage"), {
  loading: () => (
    <div className="flex h-full min-h-[min(40vh,280px)] flex-1 items-center justify-center">
      <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
    </div>
  ),
});

interface Props {
  params: Promise<{ pubId: string[] }>;
}

export default function PubPage({ params }: Props) {
  const { pubId: pubSegments } = use(params);
  const pubId = readRoutePubIdFromSegments(pubSegments);
  return <ReadPubPage key={pubId} pubId={pubId} />;
}
