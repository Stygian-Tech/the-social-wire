import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import { resolveAddPublicationInput } from "@/lib/addPublicationResolveServer";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "invalid json body" }, { status: 400 });
  }
  const input =
    typeof body === "object" &&
    body !== null &&
    "input" in body &&
    typeof (body as { input?: unknown }).input === "string"
      ? (body as { input: string }).input
      : null;
  if (input === null) {
    return NextResponse.json(
      { error: "missing string field \"input\"" },
      { status: 400 }
    );
  }

  try {
    const result = await resolveAddPublicationInput(input);
    if ("error" in result) {
      return NextResponse.json({ error: result.error }, { status: 422 });
    }
    return NextResponse.json(result);
  } catch (err) {
    console.error(err);
    return NextResponse.json({ error: "resolution failed" }, { status: 502 });
  }
}
