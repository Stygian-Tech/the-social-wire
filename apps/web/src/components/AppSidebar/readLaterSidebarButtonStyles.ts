export function readLaterSidebarButtonClassName({
  usingSemble,
  count,
}: {
  usingSemble: boolean;
  count: number;
}): string | undefined {
  const badgeSpacing = count > 0 ? "relative pr-8" : undefined;

  if (!usingSemble) return badgeSpacing;

  return [
    "h-auto min-h-[30px] py-[5px]",
    "[&>span]:min-w-0 [&>span]:flex-1 [&>span]:break-words [&>span]:leading-5",
    "[&>span]:overflow-visible! [&>span]:text-clip! [&>span]:whitespace-normal!",
    badgeSpacing,
  ]
    .filter(Boolean)
    .join(" ");
}
