import { describe, it, expect } from "bun:test";
import {
  ancestorHostFromCspToken,
  extractFrameAncestorsDirective,
  isBlockedEmbedProbeHostname,
  normalizeCspHeaderValue,
  parseFramePolicy,
  tokenizeCspDirectiveValue,
  validateHttpsEmbedProbeTarget,
} from "@/lib/embedFramePolicy";

describe("parseFramePolicy", () => {
  it("treats X-Frame-Options DENY and SAMEORIGIN as not frameable", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: "DENY",
        contentSecurityPolicy: null,
        embeddingHostHints: [],
      })
    ).toEqual({ frameable: false });
    expect(
      parseFramePolicy({
        xFrameOptions: "SAMEORIGIN",
        contentSecurityPolicy: null,
        embeddingHostHints: [],
      })
    ).toEqual({ frameable: false });
  });

  it("uses the first XFO token when multiple are comma-separated", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: "SAMEORIGIN, ALLOWALL",
        contentSecurityPolicy: null,
        embeddingHostHints: [],
      })
    ).toEqual({ frameable: false });
  });

  it("treats frame-ancestors 'none' as not frameable", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: null,
        contentSecurityPolicy: "default-src 'self'; frame-ancestors 'none'",
        embeddingHostHints: ["app.example"],
      })
    ).toEqual({ frameable: false });
  });

  it("treats frame-ancestors * as frameable", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: null,
        contentSecurityPolicy: "frame-ancestors *",
        embeddingHostHints: [],
      })
    ).toEqual({ frameable: true });
  });

  it("treats only 'self' in frame-ancestors as not frameable for third-party embeds", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: null,
        contentSecurityPolicy: "frame-ancestors 'self'",
        embeddingHostHints: ["reader.example"],
      })
    ).toEqual({ frameable: false });
  });

  it("allows frame-ancestors when a hint host matches a listed ancestor", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: null,
        contentSecurityPolicy: "frame-ancestors https://reader.example",
        embeddingHostHints: ["reader.example"],
      })
    ).toEqual({ frameable: true });
  });

  it("blocks when ancestors are listed but hints do not match", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: null,
        contentSecurityPolicy: "frame-ancestors https://other.example",
        embeddingHostHints: ["reader.example"],
      })
    ).toEqual({ frameable: false });
  });

  it("returns frameable when CSP has no frame-ancestors directive", () => {
    expect(
      parseFramePolicy({
        xFrameOptions: null,
        contentSecurityPolicy: "default-src 'self'",
        embeddingHostHints: [],
      })
    ).toEqual({ frameable: true });
  });
});

describe("validateHttpsEmbedProbeTarget", () => {
  it("accepts ordinary https URLs", () => {
    const v = validateHttpsEmbedProbeTarget("https://changelog.offprint.app/");
    expect(v.ok).toBe(true);
    if (v.ok) expect(v.url.hostname).toBe("changelog.offprint.app");
  });

  it("rejects http, file, and credentialed URLs", () => {
    expect(validateHttpsEmbedProbeTarget("http://public.example/").ok).toBe(false);
    expect(validateHttpsEmbedProbeTarget("file:///etc/passwd").ok).toBe(false);
    expect(validateHttpsEmbedProbeTarget("https://user:pass@ex.com/").ok).toBe(false);
  });
});

describe("isBlockedEmbedProbeHostname", () => {
  it("blocks loopback and RFC1918-style hosts", () => {
    expect(isBlockedEmbedProbeHostname("localhost")).toBe(true);
    expect(isBlockedEmbedProbeHostname("127.0.0.1")).toBe(true);
    expect(isBlockedEmbedProbeHostname("192.168.1.1")).toBe(true);
    expect(isBlockedEmbedProbeHostname("10.0.0.1")).toBe(true);
    expect(isBlockedEmbedProbeHostname("172.20.0.1")).toBe(true);
  });

  it("allows public hosts", () => {
    expect(isBlockedEmbedProbeHostname("changelog.offprint.app")).toBe(false);
    expect(isBlockedEmbedProbeHostname("example.com")).toBe(false);
  });
});

describe("CSP helpers", () => {
  it("extracts frame-ancestors across repeated directives", () => {
    const csp = "frame-ancestors a.com; default-src 'self'; frame-ancestors b.com";
    expect(extractFrameAncestorsDirective(csp)).toBe("a.com b.com");
  });

  it("tokenizes quoted sources", () => {
    expect(tokenizeCspDirectiveValue(`'self' https://a.com *`)).toEqual([
      "'self'",
      "https://a.com",
      "*",
    ]);
  });

  it("normalizeCspHeaderValue trims", () => {
    expect(normalizeCspHeaderValue("  a  ")).toBe("a");
  });

  it("parses host-like frame-ancestor tokens", () => {
    expect(ancestorHostFromCspToken("https://reader.example")).toEqual({
      scheme: "https",
      host: "reader.example",
    });
    expect(ancestorHostFromCspToken("reader.example")).toEqual({
      scheme: "https",
      host: "reader.example",
    });
  });
});
