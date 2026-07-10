import fs from "fs";
import path from "path";

const contentDir = path.join(process.cwd(), "content");

export function getDocContent(section: string, slug: string): string | null {
  const filePath = path.join(contentDir, section, `${slug}.md`);
  if (!fs.existsSync(filePath)) return null;
  return fs.readFileSync(filePath, "utf-8");
}

export function getAllDocs(): { section: string; slug: string }[] {
  const results: { section: string; slug: string }[] = [];
  const sections = fs
    .readdirSync(contentDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
  for (const section of sections) {
    const files = fs.readdirSync(path.join(contentDir, section)).filter((f) => f.endsWith(".md"));
    for (const file of files) {
      results.push({ section, slug: file.replace(/\.md$/, "") });
    }
  }
  return results;
}
