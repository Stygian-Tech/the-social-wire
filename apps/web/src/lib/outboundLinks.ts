/**
 * Shared attributes for links that leave the app for a publisher's site.
 *
 * Publishers see The Social Wire in their analytics only if the browser sends a `Referer`, so
 * outbound links deliberately omit `noreferrer`. `noopener` still severs `window.opener`, which is
 * the security property `noreferrer` was carrying here.
 *
 * `origin` sends `https://thesocialwire.app/` and nothing more: enough for the publisher to
 * attribute the visit, without leaking which entry the reader had open, and — unlike the browser
 * default `strict-origin-when-cross-origin` — it still sends attribution to `http://` destinations.
 */
export const OUTBOUND_LINK_REL = "noopener";

export const OUTBOUND_REFERRER_POLICY = "origin";

/** Spread onto any `<a>` pointing at a publisher: `<a href={url} {...outboundLinkProps} />`. */
export const outboundLinkProps = {
  target: "_blank",
  rel: OUTBOUND_LINK_REL,
  referrerPolicy: OUTBOUND_REFERRER_POLICY,
} as const;

/**
 * `window.open` features string. `noreferrer` here would strip the referrer *and* force a null
 * handle back, so callers that need the handle could not use it either way.
 */
export const OUTBOUND_WINDOW_FEATURES = "noopener";
