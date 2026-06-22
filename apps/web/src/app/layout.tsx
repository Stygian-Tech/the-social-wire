import type { Metadata } from "next";
import type { CSSProperties } from "react";
import { Analytics } from "@vercel/analytics/react";
import "./globals.css";
import { Providers } from "./providers";
import { EnvironmentBanner } from "@/components/shared/EnvironmentBanner";
import {
  environmentBannerHeight,
  getAppEnv,
} from "@/lib/appEnv";

const siteUrl = (() => {
  const explicit = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (explicit) return explicit.replace(/\/$/, "");
  if (process.env.VERCEL_ENV === "production") {
    return "https://thesocialwire.app";
  }
  const vercel = process.env.VERCEL_URL?.trim();
  if (vercel) return `https://${vercel.replace(/^https?:\/\//i, "")}`;
  return "https://thesocialwire.app";
})();

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "The Social Wire",
  description: "A reader for the standard.site publishing ecosystem",
  applicationName: "The Social Wire",
  appleWebApp: {
    capable: true,
    title: "The Social Wire",
    statusBarStyle: "black-translucent",
  },
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "any" },
      { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180", type: "image/png" }],
  },
  openGraph: {
    type: "website",
    title: "The Social Wire",
    description: "A reader for the standard.site publishing ecosystem",
    url: "/",
    images: [
      {
        url: "/og/the-social-wire.png",
        width: 1535,
        height: 1024,
        alt: "The Social Wire",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "The Social Wire",
    description: "A reader for the standard.site publishing ecosystem",
    images: ["/og/the-social-wire.png"],
  },
};

const appEnv = getAppEnv();

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="h-full antialiased" suppressHydrationWarning>
      <head>
        <script
          id="dark-mode"
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var root=document.documentElement;var media=window.matchMedia("(prefers-color-scheme: dark)");function apply(){var dark=media.matches;root.classList.toggle("dark",dark);root.style.colorScheme=dark?"dark":"light";}apply();if(typeof media.addEventListener==="function"){media.addEventListener("change",apply);}else if(typeof media.addListener==="function"){media.addListener(apply);}}catch(e){}})();`,
          }}
        />
      </head>
      <body
        className="min-h-full flex flex-col"
        style={
          {
            "--environment-banner-height": environmentBannerHeight(appEnv),
          } as CSSProperties
        }
      >
        <Providers>
          <EnvironmentBanner appEnv={appEnv} />
          {children}
        </Providers>
        {appEnv === "prod" ? <Analytics /> : null}
      </body>
    </html>
  );
}
