import { Badge } from "@/components/ui/badge"
import { evidenceChartModel } from "@/lib/evidence-chart"
import type { MetricPoint } from "@/lib/collection-metrics"
import type { EvidenceEnvelope } from "@/lib/operations-types"

const WIDTH = 480
const HEIGHT = 280
const PADDING = { top: 18, right: 18, bottom: 38, left: 58 }

function formatTime(timestamp?: number) {
  if (timestamp === undefined) return "—"
  return new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(timestamp)
}

function formatTick(value: number) {
  const compact = (divisor: number, suffix: string) =>
    `${(value / divisor).toFixed(value >= divisor * 10 ? 0 : 1).replace(/\.0$/, "")}${suffix}`
  if (value >= 1_000_000_000) return compact(1_000_000_000, "B")
  if (value >= 1_000_000) return compact(1_000_000, "M")
  if (value >= 1_000) return compact(1_000, "K")
  return value.toFixed(value >= 10 ? 0 : 2).replace(/\.0+$|(?<=\.[0-9])0$/, "")
}

export function EvidenceLineChart({
  points,
  title,
  unit,
  source,
  format,
  tone = "primary",
  threshold,
  refreshedAt,
  referenceTime = refreshedAt,
  sampleCount,
  evidence,
  showFreshnessBadge = true,
}: {
  points: MetricPoint[]
  title: string
  unit: string
  source: string
  format: (value: number) => string
  tone?: "primary" | "warning"
  threshold?: number
  refreshedAt: string
  referenceTime?: string
  sampleCount?: number
  evidence?: EvidenceEnvelope
  showFreshnessBadge?: boolean
}) {
  const model = evidenceChartModel(points, WIDTH, HEIGHT, PADDING, threshold)
  const stroke = tone === "warning" ? "var(--warning)" : "var(--primary)"
  const referenceMs = new Date(referenceTime).getTime()
  const bucketAgeSeconds =
    model.end !== undefined && Number.isFinite(referenceMs)
      ? Math.max(0, (referenceMs - (model.end + 60_000)) / 1_000)
      : null
  const validityMs = evidence?.validUntil ? new Date(evidence.validUntil).getTime() : Number.NaN
  const expired = Number.isFinite(validityMs) && validityMs < referenceMs
  const freshness =
    bucketAgeSeconds === null
      ? "Unknown"
      : expired || bucketAgeSeconds > 75
        ? "Stale"
        : evidence?.accuracy === "unavailable" || model.latest === null || model.coverage < 1
          ? "Partial"
          : "Fresh"
  const thresholdY =
    threshold !== undefined && threshold >= 0 && Number.isFinite(threshold) && model.maximum > 0
      ? PADDING.top + (HEIGHT - PADDING.top - PADDING.bottom) - (threshold / model.maximum) * (HEIGHT - PADDING.top - PADDING.bottom)
      : undefined
  const envelopeSource = evidence?.source
  const sourceDescription =
    envelopeSource && envelopeSource !== source
      ? `Metric source ${source}. Evidence envelope ${envelopeSource}.`
      : `Source ${source}.`
  const description = `${title}. ${model.observed} of ${model.total} one-minute buckets observed. Latest ${model.latest === null ? "missing" : format(model.latest)}. ${sourceDescription}`

  return (
    <article className="rounded-md border bg-background p-3" aria-label={title}>
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="text-xs font-semibold">{title}</h3>
          <p className="mt-1 text-[11px] text-muted-foreground">
            {formatTime(model.start)}–{formatTime(model.end)} · 1-minute closed buckets · {unit}
          </p>
        </div>
        <div className="text-right">
          <p className="font-mono text-base font-semibold">{model.latest === null ? "— Missing" : format(model.latest)}</p>
          {showFreshnessBadge ? (
            <Badge tone={freshness === "Fresh" ? "success" : freshness === "Partial" ? "warning" : "danger"}>
              {freshness}
            </Badge>
          ) : null}
        </div>
      </header>
      <svg
        className="mt-3 h-auto w-full min-w-0"
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label={description}
      >
        <title>{title}</title>
        <desc>{description}</desc>
        {[0, 0.5, 1].map((ratio) => {
          const y = PADDING.top + (1 - ratio) * (HEIGHT - PADDING.top - PADDING.bottom)
          const value = model.maximum * ratio
          return (
            <g key={ratio}>
              <line x1={PADDING.left} x2={WIDTH - PADDING.right} y1={y} y2={y} stroke="var(--border)" strokeWidth="1" />
              <text x={PADDING.left - 8} y={y + 4} textAnchor="end" fill="var(--muted-foreground)" fontSize="11">
                {formatTick(value)}
              </text>
            </g>
          )
        })}
        <text x={PADDING.left} y={HEIGHT - 9} fill="var(--muted-foreground)" fontSize="11">{formatTime(model.start)}</text>
        <text x={WIDTH - PADDING.right} y={HEIGHT - 9} textAnchor="end" fill="var(--muted-foreground)" fontSize="11">
          {formatTime(model.end)}
        </text>
        {thresholdY !== undefined ? (
          <g>
            <line
              x1={PADDING.left}
              x2={WIDTH - PADDING.right}
              y1={thresholdY}
              y2={thresholdY}
              stroke="var(--destructive)"
              strokeDasharray="5 4"
            />
            <text x={WIDTH - PADDING.right} y={thresholdY - 6} textAnchor="end" fill="var(--destructive)" fontSize="11">
              Threshold {formatTick(threshold!)}
            </text>
          </g>
        ) : null}
        {model.paths.map((path) => (
          <path key={path} d={path} fill="none" stroke={stroke} strokeWidth="2" vectorEffect="non-scaling-stroke" />
        ))}
        {model.points.length === 1 ? (
          <circle cx={model.points[0]!.x} cy={model.points[0]!.y} r="3" fill={stroke} />
        ) : null}
      </svg>
      <footer className="mt-3 flex flex-wrap items-center justify-between gap-2 border-t pt-3 text-[11px] leading-4 text-muted-foreground">
        <span>
          Source: {source}
          {envelopeSource && envelopeSource !== source ? ` · Envelope: ${envelopeSource}` : ""}
          {` · ${evidence?.accuracy ?? "reported"}`}
        </span>
        <span>Latest bucket age: {bucketAgeSeconds === null ? "unknown" : `${Math.round(bucketAgeSeconds)}s`}</span>
        <span>
          Coverage: {model.observed}/{model.total} buckets ({Math.round(model.coverage * 100)}%)
          {evidence?.coverage !== undefined ? ` · source ${Math.round(evidence.coverage * 100)}%` : ""}
        </span>
        <span>Samples: {sampleCount === undefined ? "unavailable" : sampleCount.toLocaleString()}</span>
      </footer>
    </article>
  )
}
