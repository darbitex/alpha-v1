import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsDir: "assets",
    sourcemap: false,
    target: "es2022",
    rollupOptions: {
      output: {
        manualChunks: {
          aptos: ["@aptos-labs/ts-sdk", "@aptos-labs/wallet-adapter-react"],
          react: ["react", "react-dom", "react-router-dom"],
        },
      },
    },
  },
});
