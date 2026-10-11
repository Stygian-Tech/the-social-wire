import { Suspense } from "react";
import { BrandAccountsWorkspace } from "@/components/BrandAccounts/BrandAccountsWorkspace";

export default function BrandAccountsPage() { return <Suspense fallback={<p role="status">Loading Brand Accounts…</p>}><BrandAccountsWorkspace /></Suspense>; }
