import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// One chunk per top-level node_modules package (or scoped package).
// Keeps every asset small and names them by package so diffs between
// deploys only change chunks whose source packages actually changed.
function chunkNameFor(id: string): string | undefined {
  const m = id.match(/node_modules\/(@[^/]+\/[^/]+|[^/]+)/);
  if (!m) return undefined;
  return `pkg-${m[1].replace("@", "").replace("/", "__")}`;
}

export default defineConfig({
  plugins: [react()],
  base: "/",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsDir: "assets",
    sourcemap: false,
    target: "es2022",
    chunkSizeWarningLimit: 500,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) return undefined;
          return chunkNameFor(id);
        },
      },
    },
  },
});
