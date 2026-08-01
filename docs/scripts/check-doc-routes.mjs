// SEO regression gate for the /docs migration. Every page.mdx must build at
// one canonical HTML URL and one canonical Markdown sibling; the former route
// must redirect permanently rather than render duplicate content. Canonical
// metadata, sitemap entries, llms.txt, and rendered internal links must all
// point directly into /docs so crawlers never have to choose between copies.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const docsDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = join(docsDir, "src", "app", "docs");
const distDir = join(docsDir, process.env.NEXT_DIST_DIR || ".next");
const appOutputDir = join(distDir, "server", "app");
const siteUrl = "https://native-sdk.dev";

function* mdxPages(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) yield* mdxPages(full);
    else if (entry === "page.mdx") yield full;
  }
}

function readRequired(file, route) {
  if (!existsSync(file)) {
    throw new Error(`${route}: missing build output ${file}`);
  }
  return readFileSync(file, "utf8");
}

function assertRedirect(file, destination, route) {
  const meta = JSON.parse(readRequired(file, route));
  if (meta.status !== 308 || meta.headers?.location !== destination) {
    throw new Error(
      `${route}: expected a 308 redirect to ${destination}, got ${JSON.stringify(meta)}`,
    );
  }
  if (readRequired(file.replace(/\.meta$/, ".body"), route).length === 0) {
    throw new Error(`${route}: zero-byte redirects break Next's prerender cache`);
  }
}

const pageFiles = [...mdxPages(sourceDir)];
const canonicalPaths = new Set(
  pageFiles.map((page) => {
    const slug = relative(sourceDir, dirname(page)).split(sep).join("/");
    return `/docs/${slug}`;
  }),
);
let pages = 0;

for (const page of pageFiles) {
  pages += 1;
  const slug = relative(sourceDir, dirname(page)).split(sep).join("/");
  const canonicalPath = `/docs/${slug}`;
  const canonicalUrl = `${siteUrl}${canonicalPath}`;
  const output = join(appOutputDir, "docs", slug);
  const html = readRequired(`${output}.html`, canonicalPath);

  if (!html.includes(`<link rel="canonical" href="${canonicalUrl}"/>`)) {
    throw new Error(`${canonicalPath}: missing its exact canonical link tag`);
  }
  if (!html.includes(`<meta property="og:url" content="${canonicalUrl}"/>`)) {
    throw new Error(`${canonicalPath}: Open Graph URL is not canonical`);
  }

  for (const match of html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)) {
    const href = match[1];
    if (href?.startsWith("/") && href !== "/" && !href.startsWith("/docs/")) {
      throw new Error(`${canonicalPath}: rendered internal link bypasses /docs: ${href}`);
    }
    if (href?.startsWith("/docs/")) {
      const target = href.split(/[?#]/, 1)[0];
      if (target && !canonicalPaths.has(target)) {
        throw new Error(`${canonicalPath}: rendered internal link targets no docs page: ${href}`);
      }
    }
  }

  const markdownMeta = JSON.parse(readRequired(`${output}.md.meta`, `${canonicalPath}.md`));
  if (
    markdownMeta.status !== 200 ||
    markdownMeta.headers?.["content-type"] !== "text/markdown; charset=utf-8"
  ) {
    throw new Error(`${canonicalPath}.md: expected a static text/markdown response`);
  }

  assertRedirect(
    join(appOutputDir, `${slug}.meta`),
    canonicalPath,
    `/${slug}`,
  );
  assertRedirect(
    join(appOutputDir, `${slug}.md.meta`),
    `${canonicalPath}.md`,
    `/${slug}.md`,
  );

  if (existsSync(join(appOutputDir, `${slug}.html`))) {
    throw new Error(`/${slug}: legacy URL rendered duplicate HTML instead of redirecting`);
  }
}

if (pages === 0) throw new Error("no docs page.mdx files found");

const sitemap = readRequired(join(appOutputDir, "sitemap.xml.body"), "/sitemap.xml");
for (const match of sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)) {
  const url = match[1];
  if (url !== `${siteUrl}/` && !url?.startsWith(`${siteUrl}/docs/`)) {
    throw new Error(`/sitemap.xml: legacy documentation URL ${url}`);
  }
}

const llms = readRequired(join(appOutputDir, "llms.txt.body"), "/llms.txt");
for (const line of llms.split("\n")) {
  if (line.startsWith("- [") && !line.includes(`](${siteUrl}/docs/`)) {
    throw new Error(`/llms.txt: non-canonical documentation link: ${line}`);
  }
}

console.log(
  `docs route check passed: ${pages} canonical pages, Markdown siblings, and legacy redirect pairs verified`,
);
