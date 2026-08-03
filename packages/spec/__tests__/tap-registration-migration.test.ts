import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const migration = readFileSync(
  resolve(
    import.meta.dir,
    "../../../database/migrations/20260803143000_allow_removed_tap_registrations.sql",
  ),
  "utf8",
);

describe("Tap registration migration", () => {
  test("permits a removal without a prior local registration", () => {
    expect(migration).toContain(
      "ALTER COLUMN registered_at DROP NOT NULL",
    );
  });
});
