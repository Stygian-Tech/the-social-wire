import { FeedSettingsSection } from "@/components/Account/FeedSettingsSection";
import { MyPublicationsSection } from "@/components/Account/MyPublicationsSection";
import { OpmlImportSection } from "@/components/Account/OpmlImportSection";

export default function AccountPage() {
  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-y-auto overscroll-y-contain">
      <MyPublicationsSection />
      <OpmlImportSection />
      <FeedSettingsSection />
    </div>
  );
}
