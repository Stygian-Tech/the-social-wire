import type { Metadata } from "next";
import Script from "next/script";
import "./globals.css";
import { Providers } from "./providers";
import { EnvironmentBanner } from "@/components/shared/EnvironmentBanner";

export const metadata: Metadata = {
  title: "The Social Wire",
  description: "A reader for the standard.site publishing ecosystem",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="h-full antialiased">
      <Script id="dark-mode" strategy="beforeInteractive">{`
        if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
          document.documentElement.classList.add('dark');
        }
      `}</Script>
      <body className="min-h-full flex flex-col">
        <Providers>
          <EnvironmentBanner />
          {children}
        </Providers>
      </body>
    </html>
  );
}
