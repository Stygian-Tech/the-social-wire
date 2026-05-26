/**
 * Sanitizes provider oEmbed HTML for in-app rendering.
 * Allows sandboxed iframes (common for video/rich embeds) but strips scripts.
 */

import DOMPurify from "dompurify";

import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

export function sanitizeOEmbedHtml(dirty: string): string {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return sanitizeOEmbedHtmlFallback(dirty);
  }

  const clean = DOMPurify.sanitize(dirty, {
    ALLOWED_TAGS: [
      "blockquote",
      "p",
      "a",
      "img",
      "iframe",
      "div",
      "span",
      "br",
      "strong",
      "em",
    ],
    ALLOWED_ATTR: [
      "href",
      "src",
      "alt",
      "title",
      "class",
      "width",
      "height",
      "frameborder",
      "allow",
      "allowfullscreen",
      "referrerpolicy",
      "loading",
      "data-secret",
    ],
    ALLOWED_URI_REGEXP: /^https?:/i,
    FORBID_TAGS: ["script", "style", "object", "embed", "form", "input"],
    FORBID_ATTR: [
      "onclick",
      "onload",
      "onerror",
      "onmouseover",
      "onmouseout",
      "onfocus",
      "onblur",
      "onchange",
      "onsubmit",
      "style",
    ],
  });

  const div = document.createElement("div");
  div.innerHTML = clean;

  div.querySelectorAll("iframe[src]").forEach((node) => {
    const src = node.getAttribute("src")?.trim();
    if (!src || !/^https?:\/\//i.test(src)) {
      node.remove();
      return;
    }
    node.setAttribute("src", normalizeHttpUrlToHttps(src));
    node.setAttribute("sandbox", "allow-scripts allow-same-origin allow-popups");
    node.setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
    node.setAttribute("loading", "lazy");
  });

  div.querySelectorAll("a[href]").forEach((a) => {
    const href = a.getAttribute("href") ?? "";
    if (href.startsWith("http://") || href.startsWith("https://")) {
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    }
  });

  return div.innerHTML;
}

function sanitizeOEmbedHtmlFallback(dirty: string): string {
  return dirty
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, "")
    .replace(/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "")
    .replace(/\s+(href|src)\s*=\s*(["'])\s*(?:javascript:|data:)[^"']*\2/gi, "");
}
