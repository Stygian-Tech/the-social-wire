import Link from "next/link"
import { operationsNav } from "@/components/operations/shell/operations-navigation"

export function MobileOperationsNav({ current }: { current: string }) {
  return (
    <nav aria-label="Mobile Operations" className="grid grid-cols-4 gap-1 border-b p-2 md:hidden">
      {operationsNav.map(([key, label]) => (
        <Link
          key={key}
          href={key === "overview" ? "/" : `/${key}`}
          className={`flex min-h-11 items-center justify-center rounded-md px-1.5 py-2 text-center text-[10px] ${current === key ? "bg-accent text-accent-foreground" : "text-muted-foreground"}`}
        >
          {label}
        </Link>
      ))}
    </nav>
  )
}
