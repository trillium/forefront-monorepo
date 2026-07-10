import { getDocContent, getAllDocs } from "@/lib/content";
import { DocContent } from "@/components/DocContent";
import { notFound } from "next/navigation";

export async function generateStaticParams() {
  const docs = getAllDocs();
  return docs.map(({ section, slug }) => ({ section, slug }));
}

type Props = { params: Promise<{ section: string; slug: string }> };

export default async function DocPage({ params }: Props) {
  const { section, slug } = await params;
  const content = getDocContent(section, slug);
  if (!content) notFound();
  return <DocContent content={content} />;
}

export async function generateMetadata({ params }: Props) {
  const { slug } = await params;
  return { title: `${slug} — Forefront Docs` };
}
