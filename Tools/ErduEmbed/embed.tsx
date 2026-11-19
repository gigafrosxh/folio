import { renderToStaticMarkup } from "react-dom/server";
import { DARK, ErExportSvg, LIGHT } from "./er/ErSvg";
import { REL_DARK, REL_LIGHT, RelExportSvg } from "./rel/RelSvg";
import { schemaToSql } from "./rel/sql";
import { docFromFile, FILE_VERSION } from "./store";

export interface RenderOptions {
  view: "er" | "rel" | "sql";
  dark?: boolean;
}

export interface RenderResult {
  ok: boolean;
  svg?: string;
  sql?: string;
  width?: number;
  height?: number;
  error?: string;
  names?: string[];
}

/** Highest supported .erdu file version. */
export const version = FILE_VERSION;

/** Synchronous, DOM-free entry point for offline previews and search indexing. */
export function render(text: string, opts: RenderOptions): RenderResult {
  try {
    const doc = docFromFile(text);
    const names = [
      ...doc.er.nodes
        .filter((node) => ["entity", "relationship", "attribute"].includes(node.kind))
        .map((node) => node.name),
      ...doc.rel.tables.flatMap((table) => [table.name, ...table.columns.map((column) => column.name)]),
    ];
    if (opts.view === "sql") {
      return { ok: true, sql: schemaToSql(doc.rel, doc.dialect), names };
    }
    if (opts.view !== "er" && opts.view !== "rel") {
      return { ok: false, error: "Unbekannte Ansicht" };
    }
    const svg = renderToStaticMarkup(
      opts.view === "er"
        ? <ErExportSvg diagram={doc.er} pal={opts.dark ? DARK : LIGHT} />
        : <RelExportSvg schema={doc.rel} pal={opts.dark ? REL_DARK : REL_LIGHT} />,
    );
    const viewBox = svg.match(/\bviewBox="([^"]+)"/)?.[1].trim().split(/\s+/).map(Number);
    if (!viewBox || viewBox.length !== 4 || !viewBox.every(Number.isFinite)
      || viewBox[2] <= 0 || viewBox[3] <= 0) {
      return { ok: false, error: "Ungültige Diagrammabmessungen" };
    }
    return { ok: true, svg, width: viewBox[2], height: viewBox[3], names };
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    return {
      ok: false,
      error: message === "Datei stammt aus einer neueren ERD-Ultra-Version"
        || message === "Keine gültige ERD-Ultra-Datei (.erdu)"
        ? message
        : "Die ERD-Ultra-Datei ist ungültig oder beschädigt und kann nicht gerendert werden.",
    };
  }
}

declare global {
  var ErduRender: { render: typeof render; version: typeof version };
}

globalThis.ErduRender = { render, version };
