import createMDX from "@next/mdx";
import { createRequire } from "node:module";

// Resolve the plugin to an absolute path (still a string, so the config
// stays serializable for Turbopack). A bare "remark-gfm" is require()d
// from the MDX loader's own package context, which under pnpm's strict
// module isolation cannot see this app's dependencies — production
// builds resolved it, the Turbopack dev server did not.
const require = createRequire(import.meta.url);

const withMDX = createMDX({
  options: {
    // GFM is what gives .mdx pages pipe tables (plus autolinks and
    // strikethrough) — without it, table markdown renders as a plain
    // paragraph of pipes.
    remarkPlugins: [[require.resolve("remark-gfm")]],
  },
});

/** @type {import('next').NextConfig} */
const nextConfig = {
  pageExtensions: ["ts", "tsx", "md", "mdx"],
  // CI-style builds set NEXT_DIST_DIR so `pnpm check` never shares .next
  // with a running dev server (a shared dist dir corrupts the dev cache).
  distDir: process.env.NEXT_DIST_DIR || ".next",
  // The gate builds into .next-gate INSIDE this dir; without an ignore,
  // the dev watcher sees every one of those build files land and
  // recompiles continuously whenever a gate runs.
  watchOptions: {
    ignored: ["**/.next-gate/**", "**/.next-check/**"],
  },
  async redirects() {
    return [
      // The Philosophy page became the Introduction, the opening page of the docs.
      { source: "/philosophy", destination: "/docs/introduction", permanent: true },
    ];
  },
};

export default withMDX(nextConfig);
