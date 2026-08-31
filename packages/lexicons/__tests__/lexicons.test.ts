import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = join(import.meta.dir, "..");

function collectJsonFiles(dir: string): string[] {
  const entries = readdirSync(dir, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectJsonFiles(full));
    } else if (entry.name.endsWith(".json")) {
      files.push(full);
    }
  }
  return files;
}

describe("lexicon JSON schemas", () => {
  const files = collectJsonFiles(ROOT).filter(
    (f) => !f.endsWith("package.json")
  );

  it("includes expected Social Wire collections", () => {
    const ids = files.map((file) => JSON.parse(readFileSync(file, "utf8")).id);
    expect(ids).toContain("app.thesocialwire.folder");
    expect(ids).toContain("app.thesocialwire.wireFeedback");
    expect(ids).not.toContain("app.thesocialwire.entryReadState");
    expect(ids).toContain("link.latr.saved.external");
  });

  it("stores only non-sensitive Semble destination metadata", () => {
    const schema = JSON.parse(
      readFileSync(join(ROOT, "app/thesocialwire/preferences.json"), "utf8")
    );
    const record = schema.defs.main.record.properties;
    expect(record.readLaterService.knownValues).toContain("semble");
    expect(record.readLaterConnections.properties.semble.ref).toBe(
      "#sembleConnection"
    );
    expect(schema.defs.sembleConnection.required).toEqual([
      "collectionUri",
      "collectionName",
      "connectedAt",
    ]);
    expect(schema.defs.sembleConnection.properties).not.toHaveProperty("apiKey");
    expect(schema.defs.sembleConnection.properties).not.toHaveProperty("token");
  });

  for (const file of files) {
    it(`parses ${file.replace(ROOT + "/", "")}`, () => {
      const raw = readFileSync(file, "utf8");
      const json = JSON.parse(raw) as {
        lexicon?: number;
        id?: string;
        defs?: Record<string, unknown>;
      };
      expect(json.lexicon).toBe(1);
      expect(json.id).toBeTruthy();
      expect(json.defs).toBeTruthy();
      expect(relative(ROOT, file)).toBe(`${json.id!.replaceAll(".", "/")}.json`);
    });
  }
});
