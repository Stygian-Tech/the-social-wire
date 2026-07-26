export function formatInvestigationDate(value: string) {
  return new Date(value).toLocaleString()
}
export function titleCaseInvestigationValue(value: string) {
  return value
    .split(/[_\s]+/)
    .map((part) => (part ? `${part[0]!.toUpperCase()}${part.slice(1)}` : ""))
    .join(" ")
}
