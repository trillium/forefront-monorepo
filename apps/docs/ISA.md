---
task: forefront-docs — thin Next.js docs site for Vercel
project: forefront-docs
effort: E3
phase: complete
progress: 36/36
mode: standard
started: 2026-07-09
updated: 2026-07-09
---

## Problem

The Forefront project (iOS card-stack reader + backend server) has documentation scattered across repo markdown files — `Docs/BACKEND_CONTRACT.md`, `Docs/BACKEND_SERVER.md`, and the iOS app `ISA.md`. There is no browsable, publicly-hosted docs surface. Developers, App Store reviewers, and contributors cannot reference the backend API contract or iOS app spec without repo access.

## Vision

A clean, fast Vercel-hosted docs site where developers can browse the Forefront backend contract, iOS app spec, and onboarding flow in a polished, linkable, mobile-friendly format. Feels native to the Forefront project — same visual stack as the backend, not a generic docs template. Fast to load, easy to navigate, zero friction to deploy.

## Out of Scope

- CMS or dynamic content management (docs live in `content/` as markdown files)
- Full-text search (add later)
- Authentication or user accounts
- Heavy docs framework (Nextra, Fumadocs, Docusaurus)
- Dark mode toggle UI (respects system preference via CSS `prefers-color-scheme` only)
- Edit-on-GitHub links
- Versioning / changelog UI
- Server-side APIs or database

## Principles

1. Thin means thin — no abstraction layer beyond what renders markdown in Next.js App Router
2. Mirror the backend stack exactly: same Next.js version, Tailwind v4, TypeScript, bun
3. Static export (`output: 'export'`) — docs don't need SSR; static is faster and cheaper on Vercel
4. Content in `content/` as plain markdown; no MDX, no frontmatter required

## Constraints

- Next.js 16.2.10, React 19.2.4, Tailwind v4, TypeScript, bun (matching backend exactly)
- No server-side APIs, no sqlite, no bun-specific server packages
- Must deploy to Vercel with zero custom `vercel.json` configuration
- Static export requires `generateStaticParams()` on all dynamic routes
- `react-markdown` + `remark-gfm` for markdown rendering (no heavier library)

## Goal

A standalone Next.js docs site at `~/code/forefront-docs` that mirrors the backend's exact stack, renders markdown content with code syntax via react-markdown, navigates via a sidebar, and deploys to Vercel as a static export with zero custom configuration.

## Criteria

### Project Setup
- [ ] ISC-1: `forefront-docs/` directory exists at `/Users/trilliumsmith/code/`
- [ ] ISC-2: `package.json` exists with name "forefront-docs"
- [ ] ISC-3: `package.json` lists next@16.2.10 in dependencies
- [ ] ISC-4: `package.json` lists react@19.2.4 in dependencies
- [ ] ISC-5: `package.json` scripts include dev, build, start, lint
- [ ] ISC-6: `bun.lock` exists (bun install completed)
- [ ] ISC-7: `tailwindcss` and `@tailwindcss/postcss` in devDependencies
- [ ] ISC-8: `typescript` in devDependencies
- [ ] ISC-9: `react-markdown` and `remark-gfm` in dependencies
- [ ] ISC-10: `tsconfig.json` exists and is valid JSON
- [ ] ISC-11: `postcss.config.mjs` exists with `@tailwindcss/postcss` plugin
- [ ] ISC-12: `.gitignore` excludes node_modules, .next, .env*, .vercel

### Config
- [ ] ISC-13: `next.config.ts` exists with `output: 'export'`
- [ ] ISC-14: `next.config.ts` has no `serverExternalPackages` referencing bun:sqlite

### App Router Structure
- [ ] ISC-15: `app/layout.tsx` exists as root layout
- [ ] ISC-16: `app/page.tsx` exists as home page
- [ ] ISC-17: `app/globals.css` exists with Tailwind import
- [ ] ISC-18: `app/layout.tsx` renders a `<Sidebar>` component
- [ ] ISC-19: `app/[section]/[slug]/page.tsx` exists for doc routing
- [ ] ISC-20: dynamic route exports `generateStaticParams()`

### Components
- [ ] ISC-21: `components/Sidebar.tsx` exists with nav links grouped by section
- [ ] ISC-22: `components/DocContent.tsx` renders markdown via react-markdown + remark-gfm
- [ ] ISC-23: `components/Sidebar.tsx` and `DocContent.tsx` have no TypeScript errors

### Content
- [ ] ISC-24: `content/` directory exists
- [ ] ISC-25: `content/ios/overview.md` exists with iOS app overview
- [ ] ISC-26: `content/backend/contract.md` exists seeded from `../forefront-backend/Docs/BACKEND_CONTRACT.md`
- [ ] ISC-27: `content/backend/server.md` exists seeded from `../forefront-backend/Docs/BACKEND_SERVER.md`
- [ ] ISC-28: `content/onboarding/qr.md` exists with QR onboarding flow

### Library
- [ ] ISC-29: `lib/content.ts` exists with `getDocContent(section, slug)` export
- [ ] ISC-30: `lib/content.ts` exports `getAllDocs()` returning `{section, slug}[]`
- [ ] ISC-31: `lib/content.ts` has no TypeScript errors

### Project Docs
- [ ] ISC-32: `ISA.md` exists at project root with E3+ required sections
- [ ] ISC-33: `Docs/` directory exists

### Build
- [ ] ISC-34: `bun run build` exits 0 (static export to `out/` succeeds)

### Anti-criteria
- [ ] ISC-35: Anti: no bun:sqlite, bun:ffi, or other bun-native server imports in any file
- [ ] ISC-36: Anti: no Nextra, Fumadocs, Docusaurus, or @next/mdx in package.json

## Test Strategy

| isc | type | check | threshold | tool |
|-----|------|-------|-----------|------|
| ISC-1 | filesystem | `ls ~/code/forefront-docs` | exists | Bash |
| ISC-2..9 | manifest | `cat package.json` | fields present | Read |
| ISC-10 | json | `bun -e "JSON.parse(require('fs').readFileSync('tsconfig.json','utf8'))"` | no throw | Bash |
| ISC-11 | filesystem | `cat postcss.config.mjs` | @tailwindcss/postcss present | Read |
| ISC-12 | filesystem | `cat .gitignore` | entries present | Read |
| ISC-13..14 | filesystem | `cat next.config.ts` | output: 'export', no sqlite | Read |
| ISC-15..20 | filesystem | `ls app/` | files present | Bash |
| ISC-20 | code | `grep generateStaticParams app/\[section\]/\[slug\]/page.tsx` | present | Bash |
| ISC-21..23 | filesystem | `ls components/` | files present | Bash |
| ISC-24..28 | filesystem | `ls content/*/` | files present | Bash |
| ISC-29..31 | code | `cat lib/content.ts` | exports present | Read |
| ISC-32 | filesystem | `cat ISA.md` | E3 sections present | Read |
| ISC-33 | filesystem | `ls Docs/` | exists | Bash |
| ISC-34 | build | `bun run build` | exit 0, out/ created | Bash |
| ISC-35..36 | grep | `grep -r bun:sqlite .` / `grep -E 'nextra\|fumadocs' package.json` | absent | Bash |

## Features

| name | description | satisfies | depends_on | parallelizable |
|------|-------------|-----------|------------|----------------|
| project-scaffold | package.json, tsconfig, postcss, gitignore, next.config.ts | ISC-1..14 | — | no |
| app-router | layout.tsx, page.tsx, globals.css, [section]/[slug]/page.tsx | ISC-15..20 | project-scaffold | no |
| components | Sidebar.tsx, DocContent.tsx | ISC-21..23 | app-router | yes (parallel to content-library) |
| content-library | lib/content.ts + content/ seeded from backend Docs | ISC-24..31 | project-scaffold | yes |
| meta | ISA.md, Docs/ | ISC-32..33 | project-scaffold | yes |
| build-verify | bun install + bun run build | ISC-6, ISC-34 | all | no |
| anti-verify | grep checks for banned deps/files | ISC-35..36 | project-scaffold | yes |
