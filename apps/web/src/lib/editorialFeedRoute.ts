export type EditorialFeedRoute = "wire" | "circle";

export function editorialFeedForReadRoute(
  pathname: string,
  feed: string | null,
): EditorialFeedRoute | null {
  if (pathname !== "/read") return null;
  return feed === "wire" || feed === "circle" ? feed : null;
}
