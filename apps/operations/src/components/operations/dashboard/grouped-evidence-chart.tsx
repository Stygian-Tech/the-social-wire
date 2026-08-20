"use client"

import { CartesianGrid, Line, LineChart, XAxis, YAxis } from "recharts"

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
}: {
  data: GroupedChartDatum[]
  series: GroupedChartSeries[]
  title: string
  description: string
  unit: string
  source: string
  valueFormatter?: (value: number) => string
  sampleCount?: number
}) {
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
  const ariaDescription = `${title}. ${series.length} series over ${data.length} one-minute buckets. ${observed} of ${total} values observed. Source ${source}.`

  return (
    <Card size="sm" className="rounded-md bg-background shadow-none" aria-label={title}>
      <CardHeader>
        <CardTitle className="text-xs">{title}</CardTitle>
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
          initialDimension={{ width: 720, height: 300 }}
          className="h-[300px] w-full min-w-0 aspect-auto"
          role="img"
          aria-label={ariaDescription}
        >
          <LineChart accessibilityLayer data={chartData} margin={{ top: 8, right: 18, bottom: 12, left: 4 }}>
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
              domain={[0, "auto"]}
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              width={50}
              tickFormatter={valueFormatter}
            />
            <ChartTooltip
              cursor={false}
              content={
                <ChartTooltipContent
                  indicator="line"
                  labelFormatter={(_, payload) => formatChartTime(Number(payload[0]?.payload?.timestamp))}
                  formatter={(value, name) => (
                    <div className="flex w-full min-w-44 items-center justify-between gap-3">
                      <span className="text-muted-foreground">{config[String(name)]?.label ?? String(name)}</span>
                      <span className="font-mono font-medium text-foreground tabular-nums">
                        {typeof value === "number" ? valueFormatter(value) : "— Missing"}
                      </span>
                    </div>
                  )}
                />
              }
            />
            <ChartLegend content={<ChartLegendContent className="flex-wrap gap-x-3 gap-y-1" />} />
            {series.map((item) => (
              <Line
                key={item.key}
                dataKey={item.key}
                name={item.key}
                type="linear"
                stroke={`var(--color-${item.key})`}
                strokeWidth={2}
                strokeDasharray={item.dashed ? "5 4" : undefined}
                connectNulls={false}
                dot={false}
                isAnimationActive={false}
              />
            ))}
          </LineChart>
        </ChartContainer>
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
