/**
 * Client-side HTML sanitization wrapper.
 *
 * The Social Wire API server already sanitizes entry HTML (HTMLSanitizer.swift),
 * but this client-side layer provides defence-in-depth before rendering untrusted
 * content via dangerouslySetInnerHTML.
 */

import DOMPurify from "dompurify";

import {
  OUTBOUND_LINK_REL,
  OUTBOUND_REFERRER_POLICY,
} from "@/lib/outboundLinks";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

/**
 * Sanitizes HTML content for safe rendering.
 *
 * Allows a safe subset of HTML suitable for article content:
 * - Text formatting: h1-h6, p, strong, em, s, blockquote, pre, code
 * - Lists: ul, ol, li
 * - Links: a (href restricted to https:// and mailto:)
 * - Media: img (`http:` src upgraded to `https:` after DOMPurify — see stripUnsafeURIs)
 * - Structure: div, span, hr, br, table, thead, tbody, tr, th, td
 *
 * Strips: script, style, iframe, form, input, and all event handlers.
 */
export function sanitizeHTML(dirty: string): string {
  const prepared = prepareArticleHTML(dirty);

  if (typeof window === "undefined" || typeof document === "undefined") {
    return sanitizeHTMLFallback(prepared, false);
  }

  const clean = DOMPurify.sanitize(prepared, {
    ALLOWED_TAGS: [
      "h1", "h2", "h3", "h4", "h5", "h6",
      "p", "strong", "em", "s", "del", "ins", "sub", "sup",
      "blockquote", "pre", "code", "kbd", "samp",
      "ul", "ol", "li", "dl", "dt", "dd",
      "a", "img", "audio", "video", "source",
      "div", "span", "section", "article", "aside", "header", "footer", "main",
      "hr", "br",
      "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
      "figure", "figcaption",
    ],
    ALLOWED_ATTR: [
      "href", "src", "alt", "title", "class", "id",
      "width", "height", "loading", "controls", "preload", "poster",
      "colspan", "rowspan", "scope",
    ],
    // Only allow https:// links and mailto: — no javascript:, no data:
    ALLOWED_URI_REGEXP: /^(?:https?:|mailto:|#)/i,
    // Force target="_blank" + outbound link/referrer attributes on all links
    ADD_ATTR: ["target", "rel", "referrerpolicy"],
    FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "input"],
    FORBID_ATTR: [
      "onclick", "onload", "onerror", "onmouseover", "onmouseout",
      "onfocus", "onblur", "onchange", "onsubmit", "style",
    ],
  });

  return applySafeMediaAttributes(stripUnsafeURIs(clean));
}

/**
 * Post-processes DOMPurify output to add target="_blank" and the outbound link attributes
 * (see `outboundLinks`) to all external links, so the destination publisher still receives a
 * referrer. Any `rel` the source markup carried is replaced, not merged.
 */
export function sanitizeHTMLWithLinks(dirty: string): string {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return sanitizeHTMLFallback(prepareArticleHTML(dirty), true);
  }

  const clean = sanitizeHTML(dirty);

  // Use a DOM fragment to add link attributes without a second regex pass
  const div = document.createElement("div");
  div.innerHTML = clean;

  div.querySelectorAll("a[href]").forEach((a) => {
    const href = a.getAttribute("href") ?? "";
    if (href.startsWith("http://") || href.startsWith("https://")) {
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", OUTBOUND_LINK_REL);
      a.setAttribute("referrerpolicy", OUTBOUND_REFERRER_POLICY);
    }
  });

  return div.innerHTML;
}

export function prepareArticleHTML(dirty: string): string {
  const trimmed = dirty.trim();
  if (!trimmed) return "";

  const repaired = repairEscapedHTMLWrapper(trimmed);
  const structured = looksLikeHTML(repaired)
    ? repaired
    : plainTextParagraphs(repaired);

  return linkifyBareURLs(
    normalizeMediaElements(replaceBlockedEmbeds(structured))
  );
}

function sanitizeHTMLFallback(dirty: string, addLinkAttrs: boolean): string {
  const clean = normalizeHttpAttrsInHtmlString(
    dirty
      .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "")
      .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, "")
      .replace(/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/gi, "")
      .replace(/<(?:object|embed)\b[^>]*>[\s\S]*?<\/(?:object|embed)\s*>/gi, "")
      .replace(/<(?:object|embed)\b[^>]*\/?>/gi, "")
      .replace(/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
      .replace(/\s+style\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
      .replace(/\s+(href|src)\s*=\s*(["'])\s*(?:javascript:|data:)[^"']*\2/gi, "")
  );

  if (!addLinkAttrs) return clean;

  return clean.replace(
    /<a\b(?=[^>]*\shref=(["'])https?:\/\/[^"']+\1)(?![^>]*\starget=)([^>]*)>/gi,
    `<a$2 target="_blank" rel="${OUTBOUND_LINK_REL}" referrerpolicy="${OUTBOUND_REFERRER_POLICY}">`
  );
}

function stripUnsafeURIs(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;

  div.querySelectorAll("[href], [src], [poster]").forEach((node) => {
    for (const attr of ["href", "src", "poster"]) {
      const value = node.getAttribute(attr);
      if (!value) continue;
      const trimmed = value.trim();
      if (/^(?:javascript:|data:)/i.test(trimmed)) {
        node.removeAttribute(attr);
        continue;
      }
      if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
        node.setAttribute(attr, normalizeHttpUrlToHttps(trimmed));
      }
    }
  });

  return div.innerHTML;
}

function applySafeMediaAttributes(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;

  div.querySelectorAll("audio, video").forEach((media) => {
    media.removeAttribute("autoplay");
    media.setAttribute("controls", "");
    media.setAttribute("preload", "metadata");
  });

  return div.innerHTML;
}

/** SSR / test fallback: promote `http:` in `href` / `src` so article HTML cannot trigger mixed content. */
function normalizeHttpAttrsInHtmlString(html: string): string {
  return html.replace(
    /\b(src|href|poster)\s*=\s*(["'])((?:https?):\/\/[^"']*)\2/gi,
    (_, attr: string, q: string, url: string) =>
      `${attr}=${q}${normalizeHttpUrlToHttps(url)}${q}`
  );
}

function looksLikeHTML(value: string): boolean {
  return /<[a-z][^>]*>/i.test(value);
}

function repairEscapedHTMLWrapper(value: string): string {
  const match = value.match(/^<p>\s*([\s\S]*?)\s*<\/p>$/i);
  if (!match?.[1]?.includes("&lt;")) return value;

  const decoded = decodeBasicHTMLEntities(match[1]);
  return looksLikeHTML(decoded) ? decoded : value;
}

function decodeBasicHTMLEntities(value: string): string {
  return value
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&apos;", "'")
    .replaceAll("&amp;", "&");
}

function plainTextParagraphs(value: string): string {
  return value
    .replace(/\r\n?/g, "\n")
    .split(/\n{2,}/)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean)
    .map(
      (paragraph) =>
        `<p>${paragraph
          .split("\n")
          .map((line) => escapeHTML(line.trim()))
          .join("<br>")}</p>`
    )
    .join("");
}

function replaceBlockedEmbeds(html: string): string {
  const replace = (tag: string) => {
    const source = attributeValue(tag, "src") ?? attributeValue(tag, "data");
    if (!source) return "";
    const normalized = normalizeHttpUrlToHttps(decodeBasicHTMLEntities(source));
    if (!normalized.startsWith("https://")) return "";
    return `<p class="embedded-media-fallback"><a href="${escapeHTML(
      normalized
    )}">Open Embedded Media</a></p>`;
  };

  return html
    .replace(
      /<(?:iframe|object)\b[^>]*>[\s\S]*?<\/(?:iframe|object)\s*>/gi,
      replace
    )
    .replace(/<(?:iframe|embed|object)\b[^>]*\/?>/gi, replace);
}

function normalizeMediaElements(html: string): string {
  return html.replace(/<(audio|video)\b([^>]*)>/gi, (_, tag, rawAttrs) => {
    const attrs = String(rawAttrs)
      .replace(/\s+autoplay(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/gi, "")
      .replace(/\s+controls(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/gi, "")
      .replace(/\s+preload(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/gi, "");
    return `<${tag}${attrs} controls preload="metadata">`;
  });
}

function linkifyBareURLs(html: string): string {
  const protectedTags = new Set(["a", "code", "pre", "kbd", "samp"]);
  const openProtectedTags: string[] = [];

  return html
    .split(/(<[^>]*>)/g)
    .map((part) => {
      if (!part.startsWith("<")) {
        return openProtectedTags.length > 0 ? part : linkifyText(part);
      }

      const closing = part.match(/^<\s*\/\s*([a-z0-9]+)/i)?.[1]?.toLowerCase();
      if (closing && protectedTags.has(closing)) {
        const index = openProtectedTags.lastIndexOf(closing);
        if (index >= 0) openProtectedTags.splice(index, 1);
        return part;
      }

      const opening = part.match(/^<\s*([a-z0-9]+)/i)?.[1]?.toLowerCase();
      if (
        opening &&
        protectedTags.has(opening) &&
        !/\/\s*>$/.test(part)
      ) {
        openProtectedTags.push(opening);
      }
      return part;
    })
    .join("");
}

function linkifyText(text: string): string {
  return text.replace(
    /(?:https?:\/\/|www\.)[^\s<]+/gi,
    (matched) => {
      const { url, trailing } = splitTrailingPunctuation(matched);
      const href = url.toLowerCase().startsWith("www.")
        ? `https://${url}`
        : url;
      return `<a href="${escapeHTML(href)}">${url}</a>${trailing}`;
    }
  );
}

function splitTrailingPunctuation(value: string): {
  url: string;
  trailing: string;
} {
  let url = value;
  let trailing = "";
  while (/[.,!?;:]$/.test(url)) {
    trailing = `${url.at(-1)}${trailing}`;
    url = url.slice(0, -1);
  }
  while (url.endsWith(")") && countCharacter(url, ")") > countCharacter(url, "(")) {
    trailing = `)${trailing}`;
    url = url.slice(0, -1);
  }
  return { url, trailing };
}

function countCharacter(value: string, character: string): number {
  return [...value].filter((candidate) => candidate === character).length;
}

function attributeValue(tag: string, name: string): string | undefined {
  const match = tag.match(
    new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i")
  );
  return match?.[1] ?? match?.[2] ?? match?.[3];
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
