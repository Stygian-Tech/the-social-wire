export const STANDARD_READER_LIST_COLLECTION = "app.standard-reader.list";
export const STANDARD_READER_LIST_SAVE_COLLECTION = "app.standard-reader.listSave";
export const STANDARD_READER_LIST_SAVE_SCOPE =
  "repo:app.standard-reader.listSave?action=create&action=update&action=delete";
export const STANDARD_READER_LIST_WRITE_SCOPE =
  "repo:app.standard-reader.list?action=create&action=delete";

export type CreateStandardReaderListInput = {
  name: string;
  description?: string;
  publications: string[];
  users?: string[];
};

export interface StandardReaderListRecord {
  $type: typeof STANDARD_READER_LIST_COLLECTION;
  name: string;
  description?: string;
  publications: string[];
  users?: string[];
  createdAt: string;
}

export interface StandardReaderListSaveRecord {
  $type: typeof STANDARD_READER_LIST_SAVE_COLLECTION;
  list: string;
  createdAt: string;
}

function recordUri(input: unknown, collection: string): string | null {
  if (typeof input !== "string") return null;
  const value = input.trim();
  const match = /^at:\/\/(did:[a-z]+:[A-Za-z0-9._:%-]+)\/([^/]+)\/([A-Za-z0-9._~:-]{1,512})$/.exec(value);
  return match?.[2] === collection ? value : null;
}

/** Public web links must be resolved by AppView before writing canonical PDS references. */
export function parseStandardReaderListUri(input: unknown): string | null {
  return recordUri(input, STANDARD_READER_LIST_COLLECTION);
}

export function standardReaderListShareUrl(input: string): string {
  const uri = parseStandardReaderListUri(input);
  if (!uri) throw new Error("Enter a Standard Reader list AT URI.");
  const [did, , rkey] = uri.slice(5).split("/");
  return `https://standard-reader.app/l/${encodeURIComponent(did!)}/${encodeURIComponent(rkey!)}`;
}

function datetime(value: unknown): value is string {
  return typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    Number.isFinite(Date.parse(value));
}

function boundedText(value: unknown, bytes: number, graphemes: number): value is string {
  return typeof value === "string" && new TextEncoder().encode(value).length <= bytes &&
    [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(value)].length <= graphemes;
}

export function isStandardReaderListRecord(value: unknown): value is StandardReaderListRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<StandardReaderListRecord>;
  return record.$type === STANDARD_READER_LIST_COLLECTION && boundedText(record.name, 640, 64) &&
    (record.description === undefined || boundedText(record.description, 3000, 300)) &&
    Array.isArray(record.publications) && record.publications.length <= 500 &&
    record.publications.every(uri => recordUri(uri, "site.standard.publication") === uri) &&
    (record.users === undefined || (Array.isArray(record.users) && record.users.length <= 500 &&
      record.users.every(did => typeof did === "string" && /^did:[a-z]+:[A-Za-z0-9._:%-]+$/.test(did)))) &&
    datetime(record.createdAt);
}

export function isStandardReaderListSaveRecord(value: unknown): value is StandardReaderListSaveRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<StandardReaderListSaveRecord>;
  return record.$type === STANDARD_READER_LIST_SAVE_COLLECTION &&
    parseStandardReaderListUri(record.list) === record.list && datetime(record.createdAt);
}

export function standardReaderListRecord(
  input: CreateStandardReaderListInput,
  createdAt = new Date().toISOString(),
): StandardReaderListRecord {
  const record: StandardReaderListRecord = {
    $type: STANDARD_READER_LIST_COLLECTION,
    name: input.name.trim(),
    ...(input.description?.trim() ? { description: input.description.trim() } : {}),
    publications: [...input.publications],
    ...(input.users?.length ? { users: [...input.users] } : {}),
    createdAt,
  };
  if (!record.name || !isStandardReaderListRecord(record)) {
    throw new Error("Enter a list name of up to 64 characters, a description of up to 300 characters, and valid publication or author references.");
  }
  return record;
}

export async function standardReaderListSaveRkey(uri: string): Promise<string> {
  const list = parseStandardReaderListUri(uri);
  if (!list) throw new Error("Enter a Standard Reader list AT URI.");
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(list));
  return [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}
