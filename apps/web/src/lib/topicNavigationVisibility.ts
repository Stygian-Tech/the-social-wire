import { getAppEnv, type AppEnv } from "@/lib/appEnv";

/** Local navigation remains inspectable when no Gateway is running. */
export function topicNavigationIsVisible(
  showTopic: boolean,
  serverEnabled: boolean | undefined,
  environment: AppEnv = getAppEnv(),
): boolean {
  return showTopic && (environment === "local" || serverEnabled === true);
}
