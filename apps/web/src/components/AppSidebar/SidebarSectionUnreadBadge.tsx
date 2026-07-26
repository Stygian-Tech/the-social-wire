export function SidebarSectionUnreadBadge({ count }: { count: number }) {
  if (count <= 0) return null;
  return (
    <span
      className="ml-auto inline-flex h-5 min-w-5 items-center justify-center rounded-lg bg-primary/10 px-1 text-xs font-bold text-[var(--purple-foreground)] tabular-nums"
      aria-label={`${count} unread`}
    >
      {count}
    </span>
  );
}
