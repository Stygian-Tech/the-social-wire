import { CheckCircle2, Circle } from "lucide-react"
import type { BackfillReadinessInput } from "@/lib/operations-policy"
import { backfillReadiness } from "@/lib/operations-policy"

export function BackfillReadiness({ input }: { input: BackfillReadinessInput }) {
  const requirements = backfillReadiness(input)
  const ready = requirements.every((requirement) => requirement.complete)

  return (
    <section aria-labelledby="backfill-readiness-title" className="mt-4 rounded-md border p-3">
      <div className="flex items-center justify-between gap-3">
        <h3 id="backfill-readiness-title" className="text-xs font-semibold">
          Ready to Run
        </h3>
        <span className={ready ? "text-[10px] text-success" : "text-[10px] text-muted-foreground"}>
          {ready
            ? "All Requirements Met"
            : `${requirements.filter((requirement) => requirement.complete).length} of ${requirements.length} Complete`}
        </span>
      </div>
      <ul className="mt-2 grid gap-1.5">
        {requirements.map((requirement) => (
          <li
            key={requirement.id}
            className={
              requirement.complete
                ? "flex items-center gap-2 text-[10px] text-success"
                : "flex items-center gap-2 text-[10px] text-muted-foreground"
            }
          >
            {requirement.complete ? (
              <CheckCircle2 className="size-3.5 shrink-0" />
            ) : (
              <Circle className="size-3.5 shrink-0" />
            )}
            <span>{requirement.label}</span>
          </li>
        ))}
      </ul>
    </section>
  )
}
