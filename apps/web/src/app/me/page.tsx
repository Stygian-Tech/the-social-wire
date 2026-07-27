import { FeedSettingsSection } from "@/components/Account/FeedSettingsSection";
import { MyPublicationsSection } from "@/components/Account/MyPublicationsSection";

export default function AccountPage() {
  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-y-auto overscroll-y-contain">
      <MyPublicationsSection />
      <FeedSettingsSection />
    </div>
  );
}
