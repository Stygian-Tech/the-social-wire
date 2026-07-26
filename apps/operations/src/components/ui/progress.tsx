import { cn } from "@/lib/utils"
export function Progress({
  value,
  className,
  ariaLabel,
  ariaValueText,
}: {
  value: number | null
  className?: string
  ariaLabel: string
  ariaValueText?: string
}) {
  const determinate = value !== null && Number.isFinite(value)
  const boundedValue = determinate ? Math.max(0, Math.min(100, value)) : 0
  return (
    <div
      role="progressbar"
      aria-label={ariaLabel}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={determinate ? boundedValue : undefined}
      aria-valuetext={ariaValueText}
      className={cn("h-1.5 overflow-hidden rounded-full bg-muted", className)}
    >
      <div
        className={cn(
          "h-full bg-primary motion-safe:transition-[width]",
          determinate ? undefined : "w-1/3 motion-safe:animate-[ops-indeterminate_1.4s_ease-in-out_infinite]",
        )}
        style={determinate ? { width: `${boundedValue}%` } : undefined}
      />
    </div>
  )
}
