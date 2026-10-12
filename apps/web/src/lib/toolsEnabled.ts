import { getAppEnv, isNonProd } from "@/lib/appEnv";

/** Deployment availability is independent of the viewer's Pro entitlement. */
export function toolsEnabled(): boolean {
  const flag = process.env.NEXT_PUBLIC_TOOLS_ENABLED;
  if (flag !== undefined) return flag === "true";
  return isNonProd(getAppEnv());
}
