import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { LEGACY_DIAGNOSTIC_COLLECTIONS } from "@/lib/backfill-collections"

export function BackfillCollectionSelector({
  onValueChange,
  value,
  options,
  legacyCollections = [],
  labelledBy,
}: {
  onValueChange: (value: string[]) => void
  value: readonly string[]
  options: readonly string[]
  legacyCollections?: readonly string[]
  labelledBy?: string
}) {
  const legacy = legacyCollections.filter((collection) => LEGACY_DIAGNOSTIC_COLLECTIONS.has(collection))
  const unsupported = legacyCollections.filter(
    (collection) => !options.includes(collection) && !LEGACY_DIAGNOSTIC_COLLECTIONS.has(collection),
  )

  return (
    <fieldset aria-labelledby={labelledBy} className="grid gap-1.5 rounded-lg border p-2">
      <legend className="sr-only">Collection Filters</legend>
      {options.map((collection) => {
        const checked = value.includes(collection)
        return (
          <label key={collection} className="flex min-h-8 items-center gap-2 rounded-md px-1 text-[11px] hover:bg-muted/50 [@media(pointer:coarse)]:min-h-11">
            <input
              type="checkbox"
              className="size-4 shrink-0 accent-primary"
              checked={checked}
              onChange={() => {
                onValueChange(checked ? value.filter((item) => item !== collection) : [...value, collection])
              }}
            />
            <span className="break-all font-mono">{collection}</span>
          </label>
        )
      })}
      {value.length === 0 ? (
        <p role="alert" className="mt-1 text-[10px] text-destructive">
          Scope unknown. Select at least one collection before running a dry-run.
        </p>
      ) : null}
      {legacy.length ? (
        <Alert variant="warning" className="mt-2">
          <AlertTitle>Legacy Diagnostic Scope Withheld</AlertTitle>
          <AlertDescription>
            {legacy.join(", ")} is not a registered recovery collection and cannot be selected here.
          </AlertDescription>
        </Alert>
      ) : null}
      {unsupported.length ? (
        <Alert variant="warning" className="mt-2">
          <AlertTitle>Unsupported for This Source</AlertTitle>
          <AlertDescription>
            {unsupported.join(", ")} is outside this source mode&apos;s registered recovery coverage and is withheld.
          </AlertDescription>
        </Alert>
      ) : null}
    </fieldset>
  )
}
