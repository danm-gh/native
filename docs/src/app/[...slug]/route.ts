import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { mdxToCleanMarkdown } from "@/lib/mdx-to-markdown";
import { siteUrl } from "@/lib/site";

/**
 * Serve every canonical docs page as clean Markdown beside its HTML route, and
 * permanently redirect every legacy root-level HTML/Markdown URL into /docs,
 * including the former /md/<page path> endpoints. All routes are generated
 * from the page.mdx tree at build time, so a newly added page gets its canonical
 * Markdown sibling and every compatibility redirect.
 */

export const dynamic = "force-static";
export const dynamicParams = false;

const docsDir = () => path.join(process.cwd(), "src", "app", "docs");

export async function generateStaticParams(): Promise<{ slug: string[] }[]> {
  const params: { slug: string[] }[] = [];
  async function walk(dir: string, slug: string[]): Promise<void> {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        await walk(path.join(dir, entry.name), [...slug, entry.name]);
      } else if (entry.name === "page.mdx" && slug.length > 0) {
        const markdownSlug = [...slug];
        markdownSlug[markdownSlug.length - 1] += ".md";
        params.push(
          { slug: ["docs", ...markdownSlug] },
          { slug },
          { slug: markdownSlug },
          { slug: ["md", ...slug] },
        );
      }
    }
  }
  await walk(docsDir(), []);
  return params;
}

export async function GET(_request: Request, context: { params: Promise<{ slug: string[] }> }) {
  const { slug } = await context.params;
  if (slug[0] === "md") {
    return new Response("Permanent Redirect\n", {
      status: 308,
      headers: {
        Location: `/docs/${slug.slice(1).join("/")}.md`,
        "Content-Type": "text/plain; charset=utf-8",
      },
    });
  }

  const canonical = slug[0] === "docs";
  if (!canonical) {
    return new Response("Permanent Redirect\n", {
      status: 308,
      headers: {
        Location: `/docs/${slug.join("/")}`,
        "Content-Type": "text/plain; charset=utf-8",
      },
    });
  }

  const sourceSlug = slug.slice(1);
  const filename = sourceSlug.at(-1);
  if (!filename?.endsWith(".md") || filename === ".md") {
    return new Response("Not found", { status: 404 });
  }

  sourceSlug[sourceSlug.length - 1] = filename.slice(0, -3);
  const canonicalUrl = `${siteUrl}/docs/${sourceSlug.join("/")}`;
  const filePath = path.join(docsDir(), ...sourceSlug, "page.mdx");
  // Static params come from the filesystem walk above, but never follow
  // a path that escapes src/app/docs.
  if (!filePath.startsWith(docsDir() + path.sep)) {
    return new Response("Not found", { status: 404 });
  }
  try {
    const source = await readFile(filePath, "utf8");
    return new Response(mdxToCleanMarkdown(source) + "\n", {
      headers: {
        "Content-Type": "text/markdown; charset=utf-8",
        Link: `<${canonicalUrl}>; rel="canonical"`,
      },
    });
  } catch {
    return new Response("Not found", { status: 404 });
  }
}
