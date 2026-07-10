import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Keep the built-in `bun:sqlite` driver as a runtime external — never bundle
  // it. The store (lib/store.ts) resolves it lazily at request time under Bun;
  // this stops the bundler from trying to trace it during the Node build.
  serverExternalPackages: ["bun:sqlite"],
};

export default nextConfig;
