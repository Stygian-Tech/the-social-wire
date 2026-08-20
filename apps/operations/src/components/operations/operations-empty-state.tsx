import { DatabaseZap } from "lucide-react"
import {
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "@/components/ui/empty"

export function OperationsEmptyState({
  title = "No Evidence Available",
  children,
}: {
  title?: string
  children: React.ReactNode
}) {
  return (
    <Empty className="min-h-24 gap-2 rounded-none border-0 p-4">
      <EmptyHeader className="gap-1.5">
        <EmptyMedia variant="icon" className="text-muted-foreground">
          <DatabaseZap />
        </EmptyMedia>
        <EmptyTitle className="text-xs">{title}</EmptyTitle>
        <EmptyDescription className="text-xs/relaxed">{children}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  )
}
