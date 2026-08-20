import * as React from "react"
import { cn } from "@/lib/utils"

export function Table({ className, ...props }: React.TableHTMLAttributes<HTMLTableElement>) {
  return (
    <div
      role="region"
      aria-label={props["aria-label"] ? `${props["aria-label"]} scroll region` : "Scrollable operations data table"}
      tabIndex={0}
      className="relative min-w-0 w-full overflow-x-auto overscroll-x-contain focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring/45"
    >
      <table className={cn("w-full border-collapse text-left text-[11px]", className)} {...props} />
    </div>
  )
}
export function TableHeader(props: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className="bg-muted/55 text-muted-foreground" {...props} />
}
export function TableBody(props: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody {...props} />
}
export function TableRow({ className, ...props }: React.HTMLAttributes<HTMLTableRowElement>) {
  return <tr className={cn("border-b transition-colors last:border-b-0 hover:bg-muted/35", className)} {...props} />
}
export function TableHead({ className, ...props }: React.ThHTMLAttributes<HTMLTableCellElement>) {
  return <th className={cn("h-8 whitespace-nowrap px-2.5 font-medium", className)} {...props} />
}
export function TableCell({ className, ...props }: React.TdHTMLAttributes<HTMLTableCellElement>) {
  return <td className={cn("whitespace-nowrap px-2.5 py-2 align-middle", className)} {...props} />
}
