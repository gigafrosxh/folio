# ERD-Ultra-Render-Bundle (#204)

`Resources/Web/erd/erdu-render.js` ist ERD-Ultras eigener SVG-Renderer als einzelne IIFE-Datei
(`globalThis.ErduRender.render(text, { view: "er" | "rel" | "sql", dark })`). Gebaut aus
[gigafrosxh/erd-ultra](https://github.com/gigafrosxh/erd-ultra) Commit `30e43d6` plus den Dateien in diesem Ordner:

```sh
cp embed.tsx <erd-ultra>/src/ && cp vite.embed.config.ts <erd-ultra>/ && cp embed.test.tsx <erd-ultra>/tests/
cd <erd-ultra> && npm ci && npx vitest run tests/embed.test.tsx \
  && npx vite build --config vite.embed.config.ts && cp dist-embed/erdu-render.js <folio>/Resources/Web/erd/
```

Das Bundle läuft offline in Folios Render-Seite; die `.erdu`-Datei geht nur als Zeichenkette hinein.
