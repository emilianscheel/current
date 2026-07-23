import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "current",
  description:
    "private, local-first dictation utility for mac. hold fn, speak, and release. it works everywhere.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
