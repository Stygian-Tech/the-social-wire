import { createPreparationProxy } from "@/lib/anypub/preparationProxy";

export async function POST(request: Request) {
  return createPreparationProxy({ upstream: process.env.ANYPUB_API_URL })(request);
}
