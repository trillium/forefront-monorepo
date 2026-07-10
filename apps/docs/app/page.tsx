import Link from "next/link";

export default function Home() {
  return (
    <div>
      <h1 className="text-3xl font-bold mb-4">Forefront Docs</h1>
      <p className="text-lg mb-8 opacity-70">
        Documentation for the Forefront iOS app and self-hosted backend server.
      </p>
      <div className="grid gap-4">
        <Section title="Backend" description="API contract, server setup, and endpoints" href="/backend/contract" />
        <Section title="iOS App" description="App overview, features, and architecture" href="/ios/overview" />
        <Section title="Onboarding" description="QR code onboarding and token setup" href="/onboarding/qr" />
      </div>
    </div>
  );
}

function Section({ title, description, href }: { title: string; description: string; href: string }) {
  return (
    <Link href={href} className="block p-4 border border-current/20 rounded-lg hover:border-current/40 transition-colors">
      <h2 className="text-xl font-semibold mb-1">{title}</h2>
      <p className="opacity-60">{description}</p>
    </Link>
  );
}
