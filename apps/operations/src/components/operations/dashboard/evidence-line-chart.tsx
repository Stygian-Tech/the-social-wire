"use client"

import { CartesianGrid, Line, LineChart, ReferenceLine, XAxis, YAxis } from "recharts"

import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { evidenceChartModel } from "@/lib/evidence-chart"
import type { MetricPoint } from "@/lib/collection-metrics"
import type { EvidenceEnvelope } from "@/lib/operations-types"

const WIDTH = 480
const HEIGHT = 280
const PADDING = { top: 18, right: 18, bottom: 38, left: 58 }

export function formatChartTime(timestamp?: number) {
  if (timestamp === undefined || !Number.isFinite(timestamp)) return "—"
  return new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(timestamp)
}

export function formatChartTick(value: number) {
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
  const chartPoints = points.map((point) => ({
    ...point,
    value:
      point.value !== null && Number.isFinite(point.value) && point.value >= 0
        ? point.value
        : null,
  }))
  const model = evidenceChartModel(chartPoints, WIDTH, HEIGHT, PADDING, threshold)
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
  const envelopeSource = evidence?.source
  const sourceDescription =
    envelopeSource && envelopeSource !== source
      ? `Metric source ${source}. Evidence envelope ${envelopeSource}.`
      : `Source ${source}.`
  const description = `${title}. ${model.observed} of ${model.total} one-minute buckets observed. Latest ${model.latest === null ? "missing" : format(model.latest)}. ${sourceDescription}`
  const chartConfig = {
    value: {
      label: title,
      color: tone === "warning" ? "var(--warning)" : "var(--primary)",
    },
  } satisfies ChartConfig

  return (
    <Card size="sm" className="rounded-md bg-background shadow-none" aria-label={title}>
      <CardHeader>
        <CardTitle className="text-xs">{title}</CardTitle>
        <CardDescription className="text-[11px]">
          {formatChartTime(model.start)}–{formatChartTime(model.end)} · 1-minute closed buckets · {unit}
        </CardDescription>
        <CardAction className="text-right">
          <p className="font-mono text-base font-semibold">
            {model.latest === null ? "— Missing" : format(model.latest)}
          </p>
          {showFreshnessBadge ? (
            <Badge tone={freshness === "Fresh" ? "success" : freshness === "Partial" ? "warning" : "danger"}>
              {freshness}
            </Badge>
          ) : null}
        </CardAction>
      </CardHeader>
      <CardContent>
        <ChartContainer
          config={chartConfig}
          initialDimension={{ width: WIDTH, height: HEIGHT }}
          className="h-[280px] w-full min-w-0 aspect-auto"
          role="img"
          aria-label={description}
        >
          <LineChart accessibilityLayer data={chartPoints} margin={{ top: 18, right: 18, bottom: 12, left: 4 }}>
            <CartesianGrid vertical={false} />
            <XAxis
              dataKey="timestamp"
              type="number"
              scale="time"
              domain={["dataMin", "dataMax"]}
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              minTickGap={24}
              tickFormatter={formatChartTime}
            />
            <YAxis
              domain={[0, model.maximum]}
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              width={50}
              tickFormatter={formatChartTick}
            />
            <ChartTooltip
              cursor={false}
              content={
                <ChartTooltipContent
                  indicator="line"
                  labelFormatter={(_, payload) => formatChartTime(Number(payload[0]?.payload?.timestamp))}
                  formatter={(value) => (
                    <span className="font-mono font-medium text-foreground tabular-nums">
                      {typeof value === "number" ? format(value) : "— Missing"}
                    </span>
                  )}
                />
              }
            />
            {threshold !== undefined && Number.isFinite(threshold) && threshold >= 0 ? (
              <ReferenceLine
                y={threshold}
                stroke="var(--destructive)"
                strokeDasharray="5 4"
                label={{
                  value: `Threshold ${formatChartTick(threshold)}`,
                  position: "insideTopRight",
                  fill: "var(--destructive)",
                  fontSize: 11,
                }}
              />
            ) : null}
            <Line
              dataKey="value"
              type="linear"
              stroke="var(--color-value)"
              strokeWidth={2}
              connectNulls={false}
              dot={model.points.length === 1 ? { r: 3 } : false}
              isAnimationActive={false}
            />
          </LineChart>
        </ChartContainer>
      </CardContent>
      <CardFooter className="flex flex-wrap items-center justify-between gap-2 text-[11px] leading-4 text-muted-foreground">
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
      </CardFooter>
    </Card>
  )
}
