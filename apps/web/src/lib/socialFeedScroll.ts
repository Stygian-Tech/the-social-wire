interface SocialFeedScrollPoint {
  scrollTop: number;
  anchorUri?: string;
  anchorOffset?: number;
}

const points = new Map<string, SocialFeedScrollPoint>();
const key = (did: string, feed: string) => JSON.stringify([did, feed]);

/** Keep inner feed scrolling independent of Next's document scroll restoration. */
export function rememberSocialFeedScroll(did: string, feed: string, container: HTMLElement) {
  const top = container.getBoundingClientRect().top;
  const anchor = [...container.querySelectorAll<HTMLElement>("[data-analytics-subject]")]
    .find(post => post.getBoundingClientRect().bottom > top);
  const point = {
    scrollTop: container.scrollTop,
    anchorUri: anchor?.dataset.analyticsSubject,
    anchorOffset: anchor ? anchor.getBoundingClientRect().top - top : undefined,
  };
  points.delete(key(did, feed));
  points.set(key(did, feed), point);
  while (points.size > 20) points.delete(points.keys().next().value!);
}

export function restoreSocialFeedScroll(did: string, feed: string, container: HTMLElement) {
  const point = points.get(key(did, feed));
  if (!point) return;
  const anchor = [...container.querySelectorAll<HTMLElement>("[data-analytics-subject]")]
    .find(post => post.dataset.analyticsSubject === point.anchorUri);
  container.scrollTop = anchor && point.anchorOffset !== undefined
    ? container.scrollTop + anchor.getBoundingClientRect().top - container.getBoundingClientRect().top - point.anchorOffset
    : point.scrollTop;
}
