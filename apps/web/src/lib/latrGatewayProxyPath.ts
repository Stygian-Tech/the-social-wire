/** Same-origin proxy path; upstream gateway URL is resolved server-side. */
export const LATR_GATEWAY_PROXY_PREFIX = "/api/latr-gateway";

export function latrGatewayProxyPath(gatewayPath: string): string {
  const [pathPart, queryPart] = gatewayPath.split("?", 2);
  const normalizedPath = pathPart.startsWith("/") ? pathPart : `/${pathPart}`;
  const query = queryPart ? `?${queryPart}` : "";
  return `${LATR_GATEWAY_PROXY_PREFIX}${normalizedPath}${query}`;
}
