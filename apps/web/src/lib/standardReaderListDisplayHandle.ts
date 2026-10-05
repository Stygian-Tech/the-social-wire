/** Projection placeholders such as DIDs must never be presented as account handles. */
export function standardReaderListDisplayHandle(
  value: string | undefined,
): string | null {
  if (!value || value.length > 253) return null;
  const labels = value.split(".");
  if (labels.length < 2 || !/^[a-z]/i.test(labels.at(-1)!)) return null;
  return labels.every(
    (label) =>
      label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label),
  )
    ? value
    : null;
}
