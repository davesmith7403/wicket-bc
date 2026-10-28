// Build the Wicket product guide from docs/Wicket-Product-Guide.md:
//   (a) docs/build/out/wicket-product-guide.html  — artifact body (no doctype/html/head; publish as a claude.ai artifact)
//   (b) docs/Wicket-Product-Guide.html         — standalone page, also the print source for the PDF
// Usage (from docs/build):  bun install && bun run build.ts && bun run pdf.sh
import { marked } from "marked";
import { dirname, resolve } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

const HERE = dirname(new URL(import.meta.url).pathname);
const DOCS = resolve(HERE, "..");
const SRC = resolve(DOCS, "Wicket-Product-Guide.md");
const OUT_DIR = HERE;
const md = readFileSync(SRC, "utf8");
const guideVersion = (md.match(/\| Guide version \| ([^|]+?) \|/) ?? [, "unknown"])[1].trim();

type TocPart = { id: string; label: string; chapters: { id: string; label: string }[] };
const toc: TocPart[] = [];
let firstH1Seen = false;
let tableCount = 0;

const strip = (html: string) => html.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'");

const renderer = new marked.Renderer();
const base = new marked.Renderer();

renderer.heading = function (text: string, level: number, raw: string, slugger: any) {
  const id = slugger.slug(raw.replace(/[`*_]/g, ""));
  const label = strip(text);
  if (level === 1) {
    if (!firstH1Seen) {
      firstH1Seen = true;
      return `<h1 class="doc-title" id="${id}">${text}</h1>\n`;
    }
    toc.push({ id, label, chapters: [] });
    return `<h1 class="part" id="${id}">${text}</h1>\n`;
  }
  if (level === 2) {
    const part = toc[toc.length - 1];
    if (part) part.chapters.push({ id, label });
    return `<h2 id="${id}">${text}</h2>\n`;
  }
  return `<h${level} id="${id}">${text}</h${level}>\n`;
};

renderer.table = function (header: string, body: string) {
  tableCount++;
  const cls = tableCount === 1 ? ' class="meta"' : "";
  const headless = /<th[^>]*><\/th>/.test(header) && strip(header).trim() === "";
  const thead = headless ? "" : `<thead>${header}</thead>`;
  return `<div class="table-wrap"><table${cls}>${thead}<tbody>${body}</tbody></table></div>\n`;
};

renderer.code = function (code: string, infostring: string | undefined, escaped: boolean) {
  const lang = (infostring || "").trim().split(/\s+/)[0] || "text";
  const html = base.code.call(this, code, infostring, escaped);
  return html.replace(/^<pre>/, `<pre data-lang="${lang}">`);
};

renderer.hr = function () {
  return `<hr class="part-break">\n`;
};

marked.setOptions({ renderer, gfm: true, headerIds: true, mangle: false });
let body = marked.parse(md);

// Cover block: everything before the first part break.
const firstBreak = body.indexOf('<hr class="part-break">');
const cover = body.slice(0, firstBreak);
const rest = body.slice(firstBreak);

const tocHtml = toc
  .map(
    (p) => `<li class="toc-part"><a href="#${p.id}">${p.label}</a>
      <ol>${p.chapters.map((c) => `<li><a href="#${c.id}">${c.label}</a></li>`).join("")}</ol></li>`
  )
  .join("\n");

const fonts = `<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700&family=Source+Sans+3:ital,wght@0,400;0,600;1,400&family=IBM+Plex+Mono:wght@400;500&display=swap">`;

const css = readFileSync(`${HERE}/guide.css`, "utf8");
const js = readFileSync(`${HERE}/guide.js`, "utf8");
import { mkdirSync } from "node:fs";
mkdirSync(`${OUT_DIR}/out`, { recursive: true });

const inner = `
<div class="shell">
  <header class="topbar">
    <button class="toc-toggle" type="button" aria-controls="toc" aria-expanded="false">Contents</button>
    <span class="topbar-name">Wicket</span>
    <span class="topbar-sep" aria-hidden="true"></span>
    <span class="topbar-doc">Product Guide</span>
    <span class="pill">App 1.2 · MCP 1.10 · ${guideVersion}</span>
  </header>
  <nav class="toc" id="toc" aria-label="Contents">
    <div class="toc-head"><span>Contents</span></div>
    <ol class="toc-list">${tocHtml}</ol>
  </nav>
  <main class="doc">
    <section class="cover">${cover}</section>
    <article class="body">${rest}</article>
    <footer class="colophon">Wicket Product Guide · generated from <code>docs/Wicket-Product-Guide.md</code> · guide version ${guideVersion} · the endpoint's <code>capabilities</code> is authoritative when this text and the tenant disagree.</footer>
  </main>
</div>
<script>${js}</script>`;

const title = `<title>Wicket Product Guide</title>`;

// (a) artifact body — no doctype/html/head/body; head content at the top.
writeFileSync(`${OUT_DIR}/out/wicket-product-guide.html`, `${title}\n${fonts}\n<style>\n${css}\n</style>\n${inner}\n`);

// (b) standalone for local viewing and Chrome print-to-PDF.
writeFileSync(
  resolve(DOCS, "Wicket-Product-Guide.html"),
  `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n${title}\n${fonts}\n<style>\n${css}\n</style>\n</head>\n<body>\n${inner}\n</body>\n</html>\n`
);

console.log(`parts=${toc.length} chapters=${toc.reduce((n, p) => n + p.chapters.length, 0)} tables=${tableCount}`);
