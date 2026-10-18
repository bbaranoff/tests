// node build.mjs [fichier.qmd]  →  public/index.html (+ public/source.qmd)
// Sans argument : régénère le dossier avec tout-en-un.py sur /opt/GSM/tests et le
// dernier /root/banc-max-* seulement (les anciens bancs et les archives sont exclus).
// BANC="/root/banc-max-… […]" : les runs à prendre, à la place du dernier par date
// (banc-max.sh le pose en fin de banc : le run, ou la campagne et ses deux modes).
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { Marked } from "marked";

const DIR = "/opt/GSM/tests";
let src = process.argv[2];
if (!src) {
  fs.mkdirSync("build", { recursive: true });
  src = path.resolve("build/dossier.qmd");
  const banc = (process.env.BANC || "").split(/\s+/).filter(Boolean);
  const args = banc.length ? [DIR, ...banc] : [];
  execFileSync("python3", [path.join(DIR, "tout-en-un.py"), ...args], {
    env: { ...process.env, SORTIE: src, EXCLURE: "banc-max-* archives" },
    stdio: "inherit",
  });
}
let qmd = fs.readFileSync(src, "utf8");

// --- front matter
const meta = {};
const fm = qmd.match(/^---\n([\s\S]*?)\n---\n/);
if (fm) {
  qmd = qmd.slice(fm[0].length);
  for (const k of ["title", "subtitle", "author", "date"]) {
    const m = fm[1].match(new RegExp("^" + k + ':\\s*"?(.*?)"?\\s*$', "m"));
    if (m) meta[k] = m[1];
  }
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// --- divs Quarto (::: {.callout-x collapse="true"}) hors blocs de code
const lines = qmd.split("\n");
const out = [];
let fence = null; // séquence d'ouverture active (``` ou ````…)
const divs = [];
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  const f = l.match(/^(`{3,}|~{3,})/);
  if (fence) {
    if (f && f[1][0] === fence[0] && f[1].length >= fence.length && l.trim() === f[1]) fence = null;
    out.push(l);
    continue;
  }
  if (f) { fence = f[1]; out.push(l); continue; }
  const open = l.match(/^:{3,}\s*\{([^}]*)\}\s*$/);
  if (open) {
    const cls = (open[1].match(/\.([\w-]+)/) || [, "div"])[1];
    const collapse = /collapse\s*=\s*"?true/.test(open[1]);
    let title = cls.replace(/^callout-/, "");
    if (/^#{1,6}\s/.test(lines[i + 1] || "")) title = lines[++i].replace(/^#+\s*/, "");
    if (cls.startsWith("callout")) {
      out.push("", `<details class="callout ${cls}"${collapse ? "" : " open"}><summary>${esc(title)}</summary>`, "");
      divs.push("</details>");
    } else {
      out.push("", `<div class="${cls}">`, "");
      divs.push("</div>");
    }
    continue;
  }
  if (/^:{3,}\s*$/.test(l) && divs.length) { out.push("", divs.pop(), ""); continue; }
  out.push(l);
}
qmd = out.join("\n");

// --- rendu
const toc = [];
const used = new Map();
const num = [0, 0, 0, 0, 0, 0, 0];
const slug = (t) => {
  let s = t.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^\w]+/g, "-").replace(/^-|-$/g, "") || "s";
  const n = used.get(s) || 0;
  used.set(s, n + 1);
  return n ? `${s}-${n}` : s;
};
const marked = new Marked({
  gfm: true,
  renderer: {
    heading({ tokens, depth, text }) {
      const html = this.parser.parseInline(tokens);
      const lvl = Math.max(depth - 1, 1); // ## = niveau 1
      num[lvl]++;
      for (let k = lvl + 1; k < num.length; k++) num[k] = 0;
      const n = num.slice(1, lvl + 1).join(".");
      const id = slug(text);
      if (lvl <= 3) toc.push({ lvl, id, n, html });
      return `<h${depth} id="${id}"><span class="num">${n}</span> ${html}</h${depth}>\n`;
    },
    code({ text, lang }) {
      const l = (lang || "").replace(/[{}]/g, "").split(/[\s,]/)[0];
      if (l === "mermaid") return `<pre class="mermaid-src">${esc(text)}</pre>\n`;
      return `<pre class="code"${l ? ` data-lang="${esc(l)}"` : ""}><code>${esc(text)}</code></pre>\n`;
    },
  },
});
const body = marked.parse(qmd);

const tocHtml = toc
  .map((t) => `<a class="l${t.lvl}" href="#${t.id}"><span class="num">${t.n}</span> ${t.html.replace(/<a [^>]*>|<\/a>/g, "")}</a>`)
  .join("\n");

const html = `<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(meta.title || path.basename(src))}</title>
<style>
:root{--bg:#fff;--fg:#212529;--mute:#6c757d;--line:#dee2e6;--code:#f6f8fa;--acc:#2780e3;--side:#f8f9fa}
@media (prefers-color-scheme:dark){:root{--bg:#16181c;--fg:#e3e5e8;--mute:#9aa0a6;--line:#30343a;--code:#1e2126;--acc:#6ab0ff;--side:#1b1d21}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
#toc{position:fixed;top:0;left:0;bottom:0;width:300px;overflow:auto;padding:16px 12px;border-right:1px solid var(--line);background:var(--side);font-size:13px}
#toc input{width:100%;padding:6px 8px;margin-bottom:10px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}
#toc a{display:block;color:var(--fg);text-decoration:none;padding:2px 4px;border-radius:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#toc a:hover{background:var(--line)}#toc a.l2{padding-left:16px}#toc a.l3{padding-left:28px;color:var(--mute)}
main{margin-left:300px;padding:24px 40px;max-width:1200px}
header h1{margin:0 0 4px}header p{margin:2px 0;color:var(--mute)}
.num{color:var(--mute);font-weight:400;margin-right:4px}
h2{border-bottom:1px solid var(--line);padding-bottom:4px;margin-top:2em}
a{color:var(--acc)}
table{border-collapse:collapse;margin:1em 0;display:block;overflow-x:auto;font-size:14px}
th,td{border:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}th{background:var(--side)}
pre{background:var(--code);border:1px solid var(--line);border-radius:6px;padding:10px 12px;font:12.5px/1.45 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word;max-height:70vh;overflow:auto}
code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.92em}
pre.code[data-lang]::before{content:attr(data-lang);float:right;color:var(--mute);font-size:11px}
.mermaid{text-align:center;margin:1em 0;overflow-x:auto}
details.callout{border-left:4px solid var(--acc);background:var(--side);padding:8px 14px;border-radius:4px;margin:1em 0}
details.callout summary{cursor:pointer;font-weight:600}
#burger{display:none}
@media (max-width:900px){#toc{transform:translateX(-100%);transition:.2s;z-index:10;width:85vw}#toc.open{transform:none}
main{margin-left:0;padding:16px}#burger{display:block;position:fixed;top:10px;right:10px;z-index:11;padding:6px 10px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}}
</style></head><body>
<button id="burger" aria-label="Sommaire">☰</button>
<nav id="toc"><input id="q" placeholder="Filtrer le sommaire…" type="search"><a href="source.qmd" download>⬇ source .qmd</a><hr>${tocHtml}</nav>
<main>
<header><h1>${esc(meta.title || "")}</h1>
${meta.subtitle ? `<p>${esc(meta.subtitle)}</p>` : ""}${meta.author ? `<p>${esc(meta.author)}</p>` : ""}${meta.date ? `<p>${esc(meta.date)}</p>` : ""}</header>
${body}
</main>
<script type="module">
const toc=document.getElementById("toc");
document.getElementById("burger").onclick=()=>toc.classList.toggle("open");
toc.addEventListener("click",e=>{if(e.target.closest("a[href^='#']"))toc.classList.remove("open")});
document.getElementById("q").addEventListener("input",e=>{const q=e.target.value.toLowerCase();for(const a of toc.querySelectorAll("a[href^='#']"))a.style.display=!q||a.textContent.toLowerCase().includes(q)?"":"none"});
// Mermaid rendu à la demande (118 diagrammes : seulement ceux qui deviennent visibles)
const srcs=document.querySelectorAll("pre.mermaid-src");
if(srcs.length){
  const {default:mermaid}=await import("https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs");
  mermaid.initialize({startOnLoad:false,securityLevel:"strict",theme:matchMedia("(prefers-color-scheme: dark)").matches?"dark":"default"});
  let n=0;
  const io=new IntersectionObserver(async ents=>{for(const e of ents){if(!e.isIntersecting)continue;io.unobserve(e.target);
    const pre=e.target;try{const {svg}=await mermaid.render("mmd"+(n++),pre.textContent);const d=document.createElement("div");d.className="mermaid";d.innerHTML=svg;pre.replaceWith(d)}catch(err){pre.title=String(err)}}},{rootMargin:"600px"});
  srcs.forEach(p=>io.observe(p));
}
</script>
</body></html>`;

fs.rmSync("public", { recursive: true, force: true });
fs.mkdirSync("public");
fs.writeFileSync("public/index.html", html);
fs.copyFileSync(src, "public/source.qmd");
const mb = (f) => (fs.statSync(f).size / 1048576).toFixed(1) + " Mo";
console.log(`${src} → public/index.html (${mb("public/index.html")}), ${toc.length} entrées de sommaire`);
