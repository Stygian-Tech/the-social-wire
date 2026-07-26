import type { MetricPoint } from "@/lib/collection-metrics"

export type EvidenceChartPoint = { x: number; y: number; value: number; timestamp: number }
export type EvidenceChartModel = {
  paths: string[]
  points: EvidenceChartPoint[]
  minimum: number
  maximum: number
  latest: number | null
  coverage: number
  observed: number
  total: number
  start?: number
  end?: number
}

export function evidenceChartModel(
  points: MetricPoint[],
  width: number,
  height: number,
  padding = { top: 12, right: 16, bottom: 26, left: 48 },
  threshold?: number,
): EvidenceChartModel {
  const usableWidth = Math.max(1, width - padding.left - padding.right)
  const usableHeight = Math.max(1, height - padding.top - padding.bottom)
  const values = points.flatMap(({ value }) =>
    value !== null && Number.isFinite(value) && value >= 0 ? [value] : [],
  )
  const maximumValue = values.length ? Math.max(...values) : 0
  const boundedThreshold =
    threshold !== undefined && Number.isFinite(threshold) && threshold >= 0 ? threshold : 0
  const domainMaximum = Math.max(maximumValue, boundedThreshold)
  const maximum = domainMaximum > 0 ? domainMaximum : 1
  const minimum = values.length ? Math.min(...values) : 0
  const plotted: EvidenceChartPoint[] = []
  const paths: string[] = []
  let segment: EvidenceChartPoint[] = []

  const flush = () => {
    if (!segment.length) return
    paths.push(segment.map((point, index) => `${index ? "L" : "M"}${point.x.toFixed(2)},${point.y.toFixed(2)}`).join(" "))
    segment = []
  }

  points.forEach((point, index) => {
    if (point.value === null || !Number.isFinite(point.value) || point.value < 0) {
      flush()
      return
    }
    const chartPoint = {
      x: padding.left + (points.length <= 1 ? usableWidth / 2 : (index / (points.length - 1)) * usableWidth),
      y: padding.top + usableHeight - (point.value / maximum) * usableHeight,
      value: point.value,
      timestamp: point.timestamp,
    }
    plotted.push(chartPoint)
    segment.push(chartPoint)
  })
  flush()

  const latestCandidate = points.at(-1)?.value
  const latest =
    latestCandidate !== null && latestCandidate !== undefined && Number.isFinite(latestCandidate) && latestCandidate >= 0
      ? latestCandidate
      : null
  return {
    paths,
    points: plotted,
    minimum,
    maximum,
    latest,
    coverage: points.length ? plotted.length / points.length : 0,
    observed: plotted.length,
    total: points.length,
    start: points.at(0)?.timestamp,
    end: points.at(-1)?.timestamp,
  }
}
