import { describe, expect, it } from "vitest";
import { render, version } from "../src/embed";
import { parseErDsl } from "../src/er/dsl";
import { DARK, LIGHT } from "../src/er/ErSvg";
import { REL_DARK, REL_LIGHT } from "../src/rel/RelSvg";
import { mapErToRelational } from "../src/rel/mapping";
import { schemaToSql, type SqlDialect } from "../src/rel/sql";
import { docToFile, emptyDoc, FILE_VERSION } from "../src/store";
import { EXAMPLES } from "./fixtures";

function exampleDoc() {
  const doc = emptyDoc();
  doc.er = parseErDsl(EXAMPLES[0].dsl).diagram;
  doc.rel = mapErToRelational(doc.er).schema;
  return doc;
}

describe("offline embed renderer", () => {
  it("publishes its entry point and supported file version", () => {
    expect(globalThis.ErduRender).toEqual({ render, version: FILE_VERSION });
    expect(version).toBe(FILE_VERSION);
    expect(typeof document).toBe("undefined");
  });

  for (const dark of [false, true]) {
    for (const view of ["er", "rel", "sql"] as const) {
      it(`renders ${view}, dark=${dark}, with search names`, () => {
        const doc = exampleDoc();
        const result = render(docToFile(doc), { view, dark });
        expect(result.ok).toBe(true);
        expect(result.names).toEqual([
          ...doc.er.nodes.filter((n) => ["entity", "relationship", "attribute"].includes(n.kind)).map((n) => n.name),
          ...doc.rel.tables.flatMap((t) => [t.name, ...t.columns.map((c) => c.name)]),
        ]);
        expect(result.names).toEqual(expect.arrayContaining(["Mitarbeiter", "leitet", "mitarbeiter_id"]));
        if (view === "sql") {
          expect(result.sql).toBe(schemaToSql(doc.rel, doc.dialect));
          expect(result.sql).toContain("CREATE TABLE");
          expect(result.svg).toBeUndefined();
        } else {
          expect(result.svg).toMatch(/^<svg\b/);
          const palette = view === "er" ? (dark ? DARK : LIGHT) : (dark ? REL_DARK : REL_LIGHT);
          expect(result.svg).toContain(`fill="${palette.bg}"`);
          const box = result.svg!.match(/viewBox="([^"]+)"/)![1].split(/\s+/).map(Number);
          expect(result.width).toBe(box[2]);
          expect(result.height).toBe(box[3]);
          expect(result.width).toBeGreaterThan(0);
          expect(result.height).toBeGreaterThan(0);
        }
      });
    }
  }

  it.each(["postgres", "mysql", "sqlite", "sqlserver"] as SqlDialect[])("uses the saved %s dialect", (dialect) => {
    const doc = exampleDoc();
    doc.dialect = dialect;
    expect(render(docToFile(doc), { view: "sql" }).sql).toBe(schemaToSql(doc.rel, dialect));
  });

  for (const view of ["er", "rel", "sql"] as const) {
    it.each([
      ["invalid JSON", "not JSON"],
      ["wrong format", '{"format":"other","version":1}'],
      ["future version", '{"format":"erd-ultra","version":99}'],
      ["truncated file", docToFile(exampleDoc()).slice(0, -10)],
    ])(`rejects %s in ${view}`, (_label, text) => {
      const result = render(text, { view });
      expect(result.ok).toBe(false);
      expect(result.error).toMatch(/Datei/);
      expect(result.svg).toBeUndefined();
      expect(result.sql).toBeUndefined();
    });
  }

  it("explains unsupported versions in German", () => {
    const text = JSON.stringify({ ...JSON.parse(docToFile(exampleDoc())), version: 99 });
    expect(render(text, { view: "er" })).toEqual({
      ok: false, error: "Datei stammt aus einer neueren ERD-Ultra-Version",
    });
  });

  it.each(["er", "rel"] as const)("escapes script-shaped names in %s SVG", (view) => {
    const doc = exampleDoc();
    const name = "<script>alert(1)</script>";
    doc.er.nodes.find((n) => n.kind === "entity")!.name = name;
    doc.rel.tables[0].name = name;
    doc.rel.tables[0].columns[0].name = name;
    const result = render(docToFile(doc), { view });
    expect(result.ok).toBe(true);
    expect(result.svg).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(result.svg).not.toContain("<script");
    expect(result.names).toContain(name);
  });

  it.each(["er", "rel", "sql"] as const)("renders an empty document in %s", (view) => {
    expect(render(docToFile(emptyDoc()), { view }).ok).toBe(true);
  });
});
