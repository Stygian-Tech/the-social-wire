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
const lightAppleTouchIcon = "/icons/social-wire-apple-touch-light.png";
const darkAppleTouchIcon = "/icons/social-wire-apple-touch-dark.png";

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
    apple: [
      {
        url: lightAppleTouchIcon,
        sizes: "180x180",
        type: "image/png",
        media: "(prefers-color-scheme: light)",
      },
      {
        url: darkAppleTouchIcon,
        sizes: "180x180",
        type: "image/png",
        media: "(prefers-color-scheme: dark)",
      },
    ],
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
        <link
          rel="manifest"
          href="/manifest-light.webmanifest"
          media="(prefers-color-scheme: light)"
        />
        <link
          rel="manifest"
          href="/manifest-dark.webmanifest"
          media="(prefers-color-scheme: dark)"
        />
        <link
          rel="apple-touch-icon"
          href={lightAppleTouchIcon}
          media="(prefers-color-scheme: light)"
        />
        <link
          rel="apple-touch-icon"
          href={darkAppleTouchIcon}
          media="(prefers-color-scheme: dark)"
        />
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
