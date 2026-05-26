import { getAppEnv } from "@/lib/appEnv";

export const LOCAL_LATR_GATEWAY_URL = "http://127.0.0.1:8080";
export const DEFAULT_DEV_LATR_GATEWAY_URL =
  "https://latr-link-dev-gateway.fly.dev";
export const DEFAULT_PROD_LATR_GATEWAY_URL =
  "https://latr-link-prod-gateway.fly.dev";

/** Base URL for L@tr.link gateway mutations from The Social Wire. */
export function latrGatewayBaseUrl(): string {
  const configured = process.env.NEXT_PUBLIC_LATR_GATEWAY_URL?.trim();
  if (configured) return configured.replace(/\/$/, "");

  switch (getAppEnv()) {
    case "prod":
      return DEFAULT_PROD_LATR_GATEWAY_URL;
    case "dev":
      return DEFAULT_DEV_LATR_GATEWAY_URL;
    default:
      return LOCAL_LATR_GATEWAY_URL;
  }
}
