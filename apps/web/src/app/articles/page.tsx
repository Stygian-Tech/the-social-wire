import { Suspense } from "react";
import { ArticlesWorkspace } from "@/components/Articles/ArticlesWorkspace";

export default function ArticlesPage() {
  return <Suspense fallback={<p role="status">Loading Articles…</p>}><ArticlesWorkspace /></Suspense>;
}
