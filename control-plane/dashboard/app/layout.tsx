import type { Metadata } from "next";
import Link from "next/link";
import type { ReactNode } from "react";

import "./globals.css";

export const metadata: Metadata = {
  title: "CloudBridge control plane",
  description: "Are both clouds healthy, interchangeable and worth their cost?",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <nav aria-label="Main">
          <strong>CloudBridge</strong>
          <Link href="/">Overview</Link>
          <Link href="/parity">Parity</Link>
          <Link href="/cost">Cost</Link>
        </nav>
        <main>{children}</main>
      </body>
    </html>
  );
}
