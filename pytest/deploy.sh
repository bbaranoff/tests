#!/bin/bash
# deploy.sh — construit le site de deploiement "trop joli" du GRAFCET go-live :
#   1. regenere grafcet.{html,md}, rapport.pdf et les diagrammes depuis les VRAIS
#      journaux (banc.py resout les chemins : /run/user/<uid>/osmo-nitb/logs +
#      /tmp/c54x-pont, aucun chemin en dur) ;
#   2. rend grafcet/sequence/timeline en SVG via npx @mermaid-js/mermaid-cli ;
#   3. ecrit index.html autonome (SVG inline + plots en data-URI + bouton PDF) ;
#   4. copie dans le dossier de deploy en IGNORANT le superflu (.deployignore).
#
# Usage : deploy.sh [DOSSIER_DEPLOY]   (defaut : ./deploy)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${CALYPSO_PY:-/root/.env/bin/python3}"
DST="${1:-$HERE/deploy}"
BUILD="$(mktemp -d)"
MMCLI="${CALYPSO_MMDC_PKG:-@mermaid-js/mermaid-cli@11.4.2}"
TS="$(date '+%Y-%m-%d %H:%M')"

# config puppeteer (chromium refuse root sans --no-sandbox)
PUP="${HOME:-/root}/.puppeteer.json"
[ -f "$PUP" ] || echo '{"args":["--no-sandbox","--disable-setuid-sandbox","--disable-gpu","--disable-dev-shm-usage"]}' > "$PUP"

echo "[deploy] 1/4 generation (vrais logs) -> $BUILD"
( cd "$HERE" && "$PY" grafcet_gen.py "$BUILD" >/dev/null ) || { echo "echec generation"; exit 1; }

echo "[deploy] 2/4 rendu SVG via npx ($MMCLI)"
for d in grafcet sequence timeline; do
  [ -f "$BUILD/$d.mmd" ] && npx -y "$MMCLI" -i "$BUILD/$d.mmd" -o "$BUILD/$d.svg" \
      -b transparent -p "$PUP" >/dev/null 2>&1 && echo "   $d.svg"
done

echo "[deploy] 3/4 page autonome index.html"
( cd "$HERE" && "$PY" -c "import grafcet_gen as g; print(g.write_deploy('$BUILD', '$TS'))" )

echo "[deploy] 4/4 copie vers $DST (ignore superflu)"
mkdir -p "$DST"
if command -v rsync >/dev/null; then
  rsync -a --delete --exclude-from="$HERE/.deployignore" "$BUILD"/ "$DST"/
else
  # repli sans rsync : on ne copie que l'essentiel
  rm -rf "$DST"/*; cp -f "$BUILD"/index.html "$BUILD"/rapport.pdf "$BUILD"/grafcet.html \
     "$BUILD"/grafcet.md "$BUILD"/*.svg "$BUILD"/t_*.png "$DST"/ 2>/dev/null
fi
rm -rf "$BUILD"
echo "[deploy] OK -> $DST/index.html   (PDF : $DST/rapport.pdf)"
ls -la "$DST"
