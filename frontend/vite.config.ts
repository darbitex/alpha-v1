import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Single-bundle output (no manualChunks) keeps Walrus portal cold-start
// simple: one JS asset to warm per Cloudflare POP instead of thirty-two.
// First-visit latency is slightly worse because the bundle is bigger, but
// intermittent 503s during edge warmup are far less likely.
export default defineConfig({
  plugins: [react()],
  base: "/",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsDir: "assets",
    sourcemap: false,
    target: "es2022",
    chunkSizeWarningLimit: 2500,
  },
});
