import { NextResponse } from "next/server";

import { getAppEnv, isNonProd } from "@/lib/appEnv";
import { buildLatrGatewayCredentialDiagnostics } from "@/lib/latrGatewayCredentialDiagnostics";

export const runtime = "nodejs";

/** Dev/test/local only — validates server L@tr gateway credentials without exposing secrets. */
export async function GET(): Promise<NextResponse> {
  const appEnv = getAppEnv();
  if (!isNonProd(appEnv)) {
    return NextResponse.json({ error: "not_available" }, { status: 404 });
  }

  const diagnostics = await buildLatrGatewayCredentialDiagnostics();
  return NextResponse.json(diagnostics, {
    status: diagnostics.probe.ok ? 200 : 503,
  });
}
