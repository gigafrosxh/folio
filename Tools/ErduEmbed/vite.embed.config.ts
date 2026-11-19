import { defineConfig } from "vite";

export default defineConfig({
  define: { "process.env.NODE_ENV": '"production"' },
  build: {
    copyPublicDir: false,
    outDir: "dist-embed",
    minify: true,
    lib: {
      entry: "src/embed.tsx",
      name: "ErduRender",
      formats: ["iife"],
      fileName: () => "erdu-render.js",
    },
    rollupOptions: { output: { inlineDynamicImports: true } },
  },
});
