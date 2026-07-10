"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

const nav = [
  {
    section: "Backend",
    links: [
      { label: "API Contract", href: "/backend/contract" },
      { label: "Server Setup", href: "/backend/server" },
    ],
  },
  {
    section: "iOS App",
    links: [
      { label: "Overview", href: "/ios/overview" },
    ],
  },
  {
    section: "Onboarding",
    links: [
      { label: "QR Setup", href: "/onboarding/qr" },
    ],
  },
  {
    section: "Agent API",
    links: [
      { label: "Overview", href: "/agent/overview" },
    ],
  },
];

export function Sidebar() {
  const pathname = usePathname();
  return (
    <aside className="w-56 shrink-0 border-r border-current/10 p-4 flex flex-col gap-6 h-full overflow-auto">
      <Link href="/" className="flex items-center gap-2 text-sm tracking-tight">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src="/icon.svg" width={20} height={20} alt="" />
        <span className="font-semibold">Forefront</span>
        <span className="font-light opacity-50">Docs</span>
      </Link>
      {nav.map(({ section, links }) => (
        <div key={section}>
          <p className="text-xs font-semibold uppercase tracking-wider opacity-40 mb-2">{section}</p>
          <ul className="flex flex-col gap-1">
            {links.map(({ label, href }) => (
              <li key={href}>
                <Link
                  href={href}
                  className={`text-sm block py-0.5 px-2 rounded transition-colors ${
                    pathname === href ? "bg-current/10 font-medium" : "opacity-60 hover:opacity-100"
                  }`}
                >
                  {label}
                </Link>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </aside>
  );
}
