import { redirect } from "next/navigation";

export default function LegacyPublicationsPage() {
  redirect("/me#publications");
}
