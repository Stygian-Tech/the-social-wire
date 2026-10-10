import { Skeleton } from "@/components/ui/skeleton";

export function SocialTimelineSkeleton() {
  return <div role="status" aria-label="Loading Social Posts" className="mx-auto flex w-full max-w-2xl flex-col gap-4 p-4">
    {[0, 1, 2].map(index => <div key={index} className="flex flex-col gap-3 rounded-2xl border p-4">
      <div className="flex items-center gap-3"><Skeleton className="size-10 rounded-full" /><Skeleton className="h-4 w-36" /></div>
      <Skeleton className="h-4 w-full" /><Skeleton className="h-4 w-3/4" /><Skeleton className="h-4 w-1/2" />
    </div>)}
  </div>;
}
