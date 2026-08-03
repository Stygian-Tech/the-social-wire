"use client";

import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import ReadPubPage from "./[...pubId]/ReadPubPage";

export default function ReadIndexPage() {
  return (
    <Suspense fallback={null}>
      <ReadIndexContent />
    </Suspense>
  );
}

function ReadIndexContent() {
  const params = useSearchParams();
  const folder = params.get("folder");
  const feed = params.get("feed");
  if (folder) {
    return (
      <ReadPubPage
        key={`folder:${folder}`}
        aggregateFeed={{ kind: "folder", id: folder }}
      />
    );
  }
  const kind = feed === "following" ? "following" : "subscribed";
  return (
    <ReadPubPage
      key={kind}
      aggregateFeed={{ kind }}
    />
  );
}
