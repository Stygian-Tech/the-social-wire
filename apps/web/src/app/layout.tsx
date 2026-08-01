import type { Metadata } from "next";
import type { Viewport } from "next";
import type { CSSProperties } from "react";
import { Analytics } from "@vercel/analytics/react";
import "./globals.css";
import { Providers } from "./providers";
import { EnvironmentBanner } from "@/components/shared/EnvironmentBanner";
import {
  environmentBannerHeight,
  getAppEnv,
} from "@/lib/appEnv";
import {
  BOLD_TEXT_STORAGE_KEY,
  FONT_STORAGE_KEY,
  THEME_STORAGE_KEY,
} from "@/lib/appearance";

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

const lightInstallIcon = "/icons/social-wire-icon-light-512.png";
const darkInstallIcon = "/icons/social-wire-icon-dark-512.png";
const appleTouchIcon = "/icons/social-wire-apple-touch.png";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "The Social Wire",
  description: "A reader for the standard.site publishing ecosystem",
  applicationName: "The Social Wire",
  manifest: "/manifest-light.webmanifest",
  appleWebApp: {
    capable: true,
    title: "The Social Wire",
    statusBarStyle: "default",
  },
  icons: {
    icon: [
      {
        url: lightInstallIcon,
        sizes: "512x512",
        type: "image/png",
        media: "(prefers-color-scheme: light)",
      },
      {
        url: darkInstallIcon,
        sizes: "512x512",
        type: "image/png",
        media: "(prefers-color-scheme: dark)",
      },
    ],
    apple: {
      url: appleTouchIcon,
      sizes: "180x180",
      type: "image/png",
    },
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

export const viewport: Viewport = {
  colorScheme: "light dark",
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0a0a0a" },
  ],
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
          id="appearance"
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var p=localStorage.getItem(${JSON.stringify(THEME_STORAGE_KEY)});var theme=p==="light"||p==="dark"?p:"system";var f=localStorage.getItem(${JSON.stringify(FONT_STORAGE_KEY)});var font=f==="serif"||f==="mono"?f:"sans";var bold=localStorage.getItem(${JSON.stringify(BOLD_TEXT_STORAGE_KEY)})==="1";var systemDark=window.matchMedia("(prefers-color-scheme: dark)").matches;var computed=theme==="dark"||theme==="system"&&systemDark?"dark":"light";var root=document.documentElement;root.classList.toggle("dark",computed==="dark");root.classList.toggle("light",computed==="light");root.dataset.theme=theme;root.dataset.computedTheme=computed;root.dataset.font=font;root.dataset.boldText=bold?"true":"false";root.style.colorScheme=computed;}catch(e){}})();`,
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
