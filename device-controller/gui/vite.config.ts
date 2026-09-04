import { defineConfig } from "vite";

export default defineConfig({
  root: "web",
  base: "/gui/",
  build: { outDir: "dist", emptyOutDir: true },
});
