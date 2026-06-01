import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

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
    const names = files.map((f) => f.split("/").pop());
    expect(names).toContain("app.thesocialwire.folder.json");
    expect(names).toContain("app.thesocialwire.entryReadState.json");
    expect(names).toContain("com.latr.saved.external.json");
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
    });
  }
});

describe("entryReadState example shape", () => {
  it("main record requires subjectUri and readAt", () => {
    const schema = JSON.parse(
      readFileSync(join(ROOT, "app.thesocialwire.entryReadState.json"), "utf8")
    ) as {
      defs: { main: { record: { required?: string[] } } };
    };
    expect(schema.defs.main.record.required).toContain("subjectUri");
    expect(schema.defs.main.record.required).toContain("readAt");
  });
});
