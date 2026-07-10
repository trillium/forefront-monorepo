import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";

const components: Components = {
  h1: ({ children }) => <h1 className="text-3xl font-bold mt-8 mb-4">{children}</h1>,
  h2: ({ children }) => <h2 className="text-2xl font-semibold mt-6 mb-3">{children}</h2>,
  h3: ({ children }) => <h3 className="text-xl font-semibold mt-4 mb-2">{children}</h3>,
  p: ({ children }) => <p className="mb-4 opacity-80">{children}</p>,
  code: ({ className, children, ...props }) => {
    // react-markdown v9 removed the `inline` prop. Block-level code carries a
    // `language-*` className (from the fenced-code info string) or is wrapped in
    // <pre>; inline code has neither. Fall back to className presence to decide.
    const isBlock = typeof className === "string" && className.includes("language-");
    return isBlock ? (
      <code className={`block bg-current/5 p-4 rounded-lg text-sm font-mono overflow-x-auto ${className}`} {...props}>
        {children}
      </code>
    ) : (
      <code className="bg-current/10 px-1 py-0.5 rounded text-sm font-mono" {...props}>
        {children}
      </code>
    );
  },
  pre: ({ children }) => <pre className="mb-4">{children}</pre>,
  ul: ({ children }) => <ul className="list-disc list-inside mb-4 space-y-1 opacity-80">{children}</ul>,
  ol: ({ children }) => <ol className="list-decimal list-inside mb-4 space-y-1 opacity-80">{children}</ol>,
  li: ({ children }) => <li className="ml-4">{children}</li>,
  blockquote: ({ children }) => (
    <blockquote className="border-l-4 border-current/30 pl-4 italic opacity-70 mb-4">{children}</blockquote>
  ),
  table: ({ children }) => (
    <div className="overflow-x-auto mb-4">
      <table className="w-full text-sm border-collapse">{children}</table>
    </div>
  ),
  th: ({ children }) => (
    <th className="border border-current/20 px-3 py-2 text-left font-semibold bg-current/5">{children}</th>
  ),
  td: ({ children }) => <td className="border border-current/20 px-3 py-2">{children}</td>,
  a: ({ href, children }) => (
    <a href={href} className="underline opacity-80 hover:opacity-100">{children}</a>
  ),
  hr: () => <hr className="border-current/20 my-6" />,
};

export function DocContent({ content }: { content: string }) {
  return (
    <article className="max-w-none space-y-4 leading-relaxed">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={components}>
        {content}
      </ReactMarkdown>
    </article>
  );
}
