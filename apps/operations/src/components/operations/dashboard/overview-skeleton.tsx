import { Skeleton } from "@/components/ui/skeleton"

export function OverviewSkeleton() {
  return (
    <div className="grid gap-3">
      <Skeleton className="h-24" />
      <Skeleton className="h-36" />
      <Skeleton className="h-52" />
      <Skeleton className="h-48" />
    </div>
  )
}
