import { describe, it, expect } from "bun:test";
import { resolveAddPublicationInput } from "@/lib/addPublicationResolveServer";

describe("resolveAddPublicationInput", () => {
  it("recognizes publication AT-URI", async () => {
    const r = await resolveAddPublicationInput(
      "at://did:plc:test123/site.standard.publication/abcdef"
    );
    expect(r).toEqual({
      kind: "standard-site",
      publicationAtUri: "at://did:plc:test123/site.standard.publication/abcdef",
    });
  });

  it("rejects unrelated AT-URI collections", async () => {
    const r = await resolveAddPublicationInput(
      "at://did:plc:test123/site.standard.document/def"
    );
    expect(r).toHaveProperty("error");
    if ("error" in r) expect(r.error).toContain("Unsupported AT-URI");
  });
});
