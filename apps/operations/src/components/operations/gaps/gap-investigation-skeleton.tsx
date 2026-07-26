import { Skeleton } from "@/components/ui/skeleton"

export function GapInvestigationSkeleton() {
  return (
    <div className="grid gap-4">
      <Skeleton className="h-28" />
      <Skeleton className="h-16" />
      <Skeleton className="h-24" />
      <Skeleton className="h-20" />
    </div>
  )
}
