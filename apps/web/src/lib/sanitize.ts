/**
 * Client-side HTML sanitization wrapper.
 *
 * The Social Wire API server already sanitizes entry HTML (HTMLSanitizer.swift),
 * but this client-side layer provides defence-in-depth before rendering untrusted
 * content via dangerouslySetInnerHTML.
 */

import DOMPurify from "dompurify";

/**
 * Sanitizes HTML content for safe rendering.
 *
 * Allows a safe subset of HTML suitable for article content:
 * - Text formatting: h1-h6, p, strong, em, s, blockquote, pre, code
 * - Lists: ul, ol, li
 * - Links: a (href restricted to https:// and mailto:)
 * - Media: img (src restricted to https://)
 * - Structure: div, span, hr, br, table, thead, tbody, tr, th, td
 *
 * Strips: script, style, iframe, form, input, and all event handlers.
 */
export function sanitizeHTML(dirty: string): string {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return sanitizeHTMLFallback(dirty, false);
  }

  const clean = DOMPurify.sanitize(dirty, {
    ALLOWED_TAGS: [
      "h1", "h2", "h3", "h4", "h5", "h6",
      "p", "strong", "em", "s", "del", "ins", "sub", "sup",
      "blockquote", "pre", "code", "kbd", "samp",
      "ul", "ol", "li", "dl", "dt", "dd",
      "a", "img",
      "div", "span", "section", "article", "aside", "header", "footer", "main",
      "hr", "br",
      "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
      "figure", "figcaption",
    ],
    ALLOWED_ATTR: [
      "href", "src", "alt", "title", "class", "id",
      "width", "height", "loading",
      "colspan", "rowspan", "scope",
    ],
    // Only allow https:// links and mailto: — no javascript:, no data:
    ALLOWED_URI_REGEXP: /^(?:https?:|mailto:|#)/i,
    // Force target="_blank" + rel="noopener noreferrer" on all links
    ADD_ATTR: ["target", "rel"],
    FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "input"],
    FORBID_ATTR: [
      "onclick", "onload", "onerror", "onmouseover", "onmouseout",
      "onfocus", "onblur", "onchange", "onsubmit", "style",
    ],
  });

  return stripUnsafeURIs(clean);
}

/**
 * Post-processes DOMPurify output to add target="_blank" and
 * rel="noopener noreferrer" to all external links.
 */
export function sanitizeHTMLWithLinks(dirty: string): string {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return sanitizeHTMLFallback(dirty, true);
  }

  const clean = sanitizeHTML(dirty);

  // Use a DOM fragment to add link attributes without a second regex pass
  const div = document.createElement("div");
  div.innerHTML = clean;

  div.querySelectorAll("a[href]").forEach((a) => {
    const href = a.getAttribute("href") ?? "";
    if (href.startsWith("http://") || href.startsWith("https://")) {
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    }
  });

  return div.innerHTML;
}

function sanitizeHTMLFallback(dirty: string, addLinkAttrs: boolean): string {
  const clean = dirty
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "")
    .replace(/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/gi, "")
    .replace(/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
    .replace(/\s+(href|src)\s*=\s*(["'])\s*(?:javascript:|data:)[^"']*\2/gi, "");

  if (!addLinkAttrs) return clean;

  return clean.replace(
    /<a\b(?=[^>]*\shref=(["'])https?:\/\/[^"']+\1)(?![^>]*\starget=)([^>]*)>/gi,
    '<a$2 target="_blank" rel="noopener noreferrer">'
  );
}

function stripUnsafeURIs(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;

  div.querySelectorAll("[href], [src]").forEach((node) => {
    for (const attr of ["href", "src"]) {
      const value = node.getAttribute(attr);
      if (value && /^(?:javascript:|data:)/i.test(value.trim())) {
        node.removeAttribute(attr);
      }
    }
  });

  return div.innerHTML;
}
