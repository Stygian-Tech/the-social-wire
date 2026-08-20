"use client"

import { useQuery } from "@tanstack/react-query"
import { ArrowRight, Search, XCircle } from "lucide-react"
import { GapInvestigationContent } from "@/components/operations/gaps/gap-investigation-content"
import { GapInvestigationSkeleton } from "@/components/operations/gaps/gap-investigation-skeleton"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { useOperationsAuth } from "@/lib/auth-context"
import { fetchGapInvestigation } from "@/lib/operations-api"
import type { Gap } from "@/lib/operations-types"

export function GapInvestigationSheet({
  gap,
  open,
  onOpenChange,
  onBackfill,
  mutationsEnabled = true,
}: {
  gap?: Gap
  open: boolean
  onOpenChange: (open: boolean) => void
  onBackfill: (gap: Gap) => void
  mutationsEnabled?: boolean
}) {
  const auth = useOperationsAuth()
  const investigation = useQuery({
    queryKey: ["gap-investigation", gap?.id],
    queryFn: () => fetchGapInvestigation(auth.session, gap!.id),
    enabled: open && Boolean(gap),
  })
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-[min(96vw,560px)]">
        <SheetHeader>
          <div className="flex items-center gap-2">
            <Search className="size-4 text-primary" />
            <SheetTitle className="text-sm font-semibold">Investigate Gap</SheetTitle>
          </div>
          <SheetDescription className="mt-1 font-mono text-[10px]">{gap?.id}</SheetDescription>
        </SheetHeader>
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-3.5">
          {investigation.isLoading ? (
            <GapInvestigationSkeleton />
          ) : investigation.data ? (
            <GapInvestigationContent investigation={investigation.data} />
          ) : (
            <Alert variant="destructive">
              <XCircle className="mb-1 size-4" />
              <AlertDescription>
                {investigation.error instanceof Error
                  ? investigation.error.message
                  : "Investigation evidence could not be loaded."}
              </AlertDescription>
            </Alert>
          )}
        </div>
        {investigation.data ? (
          <SheetFooter className="flex flex-col items-stretch gap-2.5 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-[10px] text-muted-foreground">Review evidence before choosing recovery scope.</p>
            <Button
              disabled={
                !mutationsEnabled ||
                investigation.data.gap.version === undefined ||
                !["confirmed", "verification_required"].includes(investigation.data.gap.status)
              }
              title={
                !mutationsEnabled
                  ? "Recovery mutations are disabled"
                  : investigation.data.gap.version === undefined
                    ? "Gap version evidence is unavailable"
                    : !["confirmed", "verification_required"].includes(investigation.data.gap.status)
                      ? "This gap is not in a recoverable lifecycle state"
                      : undefined
              }
              onClick={() => onBackfill(investigation.data.gap)}
            >
              Backfill This Gap <ArrowRight />
            </Button>
          </SheetFooter>
        ) : null}
      </SheetContent>
    </Sheet>
  )
}
