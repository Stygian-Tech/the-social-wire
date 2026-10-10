import { ProfileInformation } from "@/components/Account/ProfileInformation";
import { ProfileContent } from "@/components/Account/ProfileContent";

export default function AccountPage() {
  return <div className="flex min-h-0 flex-1 flex-col overflow-y-auto overscroll-y-contain">
    <ProfileInformation />
    <ProfileContent />
  </div>;
}
