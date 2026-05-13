interface AvatarProps {
  src?: string | null;
  alt: string;
  size?: number;
  className?: string;
}

export function Avatar({ src, alt, size = 32, className = "" }: AvatarProps) {
  if (src) {
    return (
      <img
        src={src}
        alt={alt}
        width={size}
        height={size}
        className={`rounded-full object-cover ${className}`}
        referrerPolicy="no-referrer"
      />
    );
  }

  // Fallback: initials avatar
  const initials = alt
    .split(" ")
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("");

  return (
    <span
      aria-label={alt}
      style={{ width: size, height: size }}
      className={`inline-flex items-center justify-center rounded-full bg-muted text-muted-foreground text-xs font-semibold select-none ${className}`}
    >
      {initials || "?"}
    </span>
  );
}
