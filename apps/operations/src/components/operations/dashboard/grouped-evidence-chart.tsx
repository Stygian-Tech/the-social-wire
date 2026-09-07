"use client"

import { useId } from "react"
import { Area, AreaChart, CartesianGrid, XAxis, YAxis } from "recharts"

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
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { formatChartTick, formatChartTime } from "@/components/operations/dashboard/evidence-line-chart"

export type GroupedChartDatum = { timestamp: number } & Record<string, number | null>
export type GroupedChartSeries = {
  key: string
  label: string
  color: string
  dashed?: boolean
}

export function GroupedEvidenceChart({
  data,
  series,
  title,
  description,
  unit,
  source,
  valueFormatter = formatChartTick,
  sampleCount,
  timeFormatter = formatChartTime,
  bucketLabel = "one-minute buckets",
  showIsolatedDots = false,
}: {
  data: GroupedChartDatum[]
  series: GroupedChartSeries[]
  title: string
  description: string
  unit: string
  source: string
  valueFormatter?: (value: number) => string
  sampleCount?: number
  timeFormatter?: (timestamp: number) => string
  bucketLabel?: string
  showIsolatedDots?: boolean
}) {
  const dataTableId = useId()
  const config = Object.fromEntries(
    series.map((item) => [item.key, { label: item.label, color: item.color }]),
  ) satisfies ChartConfig
  const chartData = data.map((datum) => {
    const sanitized = { ...datum }
    for (const { key } of series) {
      const value = sanitized[key]
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) sanitized[key] = null
    }
    return sanitized
  })
  const observed = chartData.reduce(
    (count, datum) => count + series.filter(({ key }) => datum[key] !== null && datum[key] !== undefined).length,
    0,
  )
  const total = data.length * series.length
  const coverage = total ? observed / total : 0
  const ariaDescription = `${title}. ${series.length} series over ${data.length} ${bucketLabel}. ${observed} of ${total} values observed. Source ${source}.`

  return (
    <Card size="sm" className="ops-chart-card" aria-label={title}>
      <CardHeader>
        <CardTitle className="text-xs"><h3>{title}</h3></CardTitle>
        <CardDescription className="text-[11px]">
          {description} · {unit}
        </CardDescription>
        <CardAction>
          <Badge tone={observed > 0 ? "info" : "neutral"}>{series.length} series</Badge>
        </CardAction>
      </CardHeader>
      <CardContent>
        <ChartContainer
          config={config}
          initialDimension={{ width: 720, height: 240 }}
          className="h-[240px] w-full min-w-0 aspect-auto"
          role="img"
          aria-label={ariaDescription}
          aria-describedby={dataTableId}
        >
          <AreaChart accessibilityLayer data={chartData} margin={{ top: 8, right: 12, bottom: 8, left: 0 }}>
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
              tickFormatter={timeFormatter}
            />
            <YAxis
              domain={[0, "auto"]}
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
                  labelFormatter={(_, payload) => timeFormatter(Number(payload[0]?.payload?.timestamp))}
                  formatter={(value, name) => (
                    <div className="flex w-full min-w-44 items-center justify-between gap-3">
                      <span className="flex items-center gap-2 text-muted-foreground">
                        <span aria-hidden className="size-2 shrink-0 rounded-full" style={{ backgroundColor: `var(--color-${name})` }} />
                        {config[String(name)]?.label ?? String(name)}
                      </span>
                      <span className="font-mono font-medium text-foreground tabular-nums">
                        {typeof value === "number" ? valueFormatter(value) : "— Missing"}
                      </span>
                    </div>
                  )}
                />
              }
            />
            <ChartLegend content={<ChartLegendContent className="flex-wrap gap-x-3 gap-y-1" />} />
            {series.map((item, index) => (
              <Area
                key={item.key}
                dataKey={item.key}
                name={item.key}
                type="monotone"
                stroke={`var(--color-${item.key})`}
                fill={`var(--color-${item.key})`}
                fillOpacity={series.length === 1 ? 0.25 : 0.12}
                baseValue={0}
                strokeWidth={2}
                strokeDasharray={item.dashed ? "5 4" : undefined}
                activeDot={{ r: 4, stroke: "var(--background)", strokeWidth: 2 }}
                connectNulls={false}
                dot={showIsolatedDots ? ({ cx, cy, index: pointIndex }) => {
                  const current = chartData[pointIndex ?? 0]?.[item.key]
                  const previous = chartData[(pointIndex ?? 0) - 1]?.[item.key]
                  const next = chartData[(pointIndex ?? 0) + 1]?.[item.key]
                  const isolated = typeof current === "number" && previous == null && next == null
                  return <circle key={pointIndex} cx={cx} cy={cy} r={isolated ? 3 : 0} fill={`var(--color-${item.key})`} />
                } : chartData.length === 1 ? { r: 3 + (index % 2) } : false}
                isAnimationActive={false}
              />
            ))}
          </AreaChart>
        </ChartContainer>
        <table id={dataTableId} className="sr-only">
          <caption>{title} time-series data</caption>
          <thead>
            <tr>
              <th scope="col">Time</th>
              {series.map((item) => <th key={item.key} scope="col">{item.label}</th>)}
            </tr>
          </thead>
          <tbody>
            {chartData.map((datum) => (
              <tr key={datum.timestamp}>
                <th scope="row">{timeFormatter(datum.timestamp)}</th>
                {series.map((item) => {
                  const value = datum[item.key]
                  return <td key={item.key}>{typeof value === "number" ? valueFormatter(value) : "Missing"}</td>
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </CardContent>
      <CardFooter className="flex flex-wrap justify-between gap-2 text-[11px] text-muted-foreground">
        <span>Source: {source}</span>
        <span>Coverage: {observed}/{total} values ({Math.round(coverage * 100)}%)</span>
        <span>Samples: {sampleCount === undefined ? "unavailable" : sampleCount.toLocaleString()}</span>
      </CardFooter>
    </Card>
  )
}

export function mergeGroupedSeries(
  inputs: Array<{ key: string; points: Array<{ timestamp: number; value: number | null }> }>,
): GroupedChartDatum[] {
  const rows = new Map<number, GroupedChartDatum>()
  for (const input of inputs) {
    for (const point of input.points) {
      const row = rows.get(point.timestamp) ?? ({ timestamp: point.timestamp } as GroupedChartDatum)
      row[input.key] = point.value
      rows.set(point.timestamp, row)
    }
  }
  const keys = inputs.map(({ key }) => key)
  return [...rows.values()]
    .sort((left, right) => left.timestamp - right.timestamp)
    .map((row) => {
      for (const key of keys) if (!(key in row)) row[key] = null
      return row
    })
}
