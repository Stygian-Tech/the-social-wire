"use client"

import { useId } from "react"
import { Area, AreaChart, CartesianGrid, ReferenceLine, XAxis, YAxis } from "recharts"

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
  const dataTableId = useId()
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
      color: tone === "warning" ? "var(--chart-4)" : "var(--chart-1)",
    },
  } satisfies ChartConfig

  return (
    <Card size="sm" className="ops-chart-card" aria-label={title}>
      <CardHeader>
        <CardTitle className="text-xs"><h3>{title}</h3></CardTitle>
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
          className="h-[240px] w-full min-w-0 aspect-auto"
          role="img"
          aria-label={description}
          aria-describedby={dataTableId}
        >
          <AreaChart accessibilityLayer data={chartPoints} margin={{ top: 18, right: 12, bottom: 8, left: 0 }}>
            <CartesianGrid vertical={false} stroke="var(--border)" strokeOpacity={0.55} strokeDasharray="3 3" />
            <XAxis
              dataKey="timestamp"
              type="number"
              scale="time"
              domain={["dataMin", "dataMax"]}
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              minTickGap={24}
              tick={{ fontSize: 10 }}
              tickFormatter={formatChartTime}
            />
            <YAxis
              domain={[0, model.maximum]}
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              width={50}
              tick={{ fontSize: 10 }}
              tickFormatter={formatChartTick}
            />
            <ChartTooltip
              cursor={{ stroke: "var(--muted-foreground)", strokeOpacity: 0.4, strokeDasharray: "3 3" }}
              content={
                <ChartTooltipContent
                  className="ops-chart-tooltip"
                  indicator="dot"
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
            <Area
              dataKey="value"
              type="monotone"
              stroke="var(--color-value)"
              fill="var(--color-value)"
              fillOpacity={0.25}
              baseValue={0}
              strokeWidth={2}
              activeDot={{ r: 4, stroke: "var(--background)", strokeWidth: 2 }}
              connectNulls={false}
              dot={model.points.length === 1 ? { r: 3 } : false}
              isAnimationActive={false}
            />
          </AreaChart>
        </ChartContainer>
        <table id={dataTableId} className="sr-only">
          <caption>{title} time-series data</caption>
          <thead>
            <tr><th scope="col">Time</th><th scope="col">{unit}</th></tr>
          </thead>
          <tbody>
            {chartPoints.map((point) => (
              <tr key={point.timestamp}>
                <th scope="row">{formatChartTime(point.timestamp)}</th>
                <td>{point.value === null ? "Missing" : format(point.value)}</td>
              </tr>
            ))}
          </tbody>
        </table>
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
