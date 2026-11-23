#!/usr/bin/env bash
# setup-vendor.sh — same as setup-vendor.ps1, for Linux / macOS.
#
# Copies the installed dsh-codearts bundle into vendor/ and links the four
# @deepseek-ai packages it imports at runtime from your DSH installation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${ROOT}/vendor/dsh-codearts"
PACKAGES=(schemastery dsh-llm dsh-llm-pi-ai dsh-settings)

PLUGIN_DIR="${CODEARTS_PLUGIN_DIR:-}"
if [ -z "$PLUGIN_DIR" ]; then
  for candidate in "$HOME"/.dsh/profiles/*/node_modules/dsh-codearts; do
    if [ -f "${candidate}/lib/index.mjs" ]; then PLUGIN_DIR="$candidate"; break; fi
  done
fi
if [ -z "$PLUGIN_DIR" ] || [ ! -f "${PLUGIN_DIR}/lib/index.mjs" ]; then
  echo "dsh-codearts not found. Install the DSH plugin first, or set CODEARTS_PLUGIN_DIR." >&2
  exit 1
fi

DSH_MODULES="${DSH_NODE_MODULES:-}"
if [ -z "$DSH_MODULES" ]; then
  for candidate in \
    "/usr/lib/dsh/resources/app/dsh/node_modules/@deepseek-ai" \
    "/opt/dsh/resources/app/dsh/node_modules/@deepseek-ai" \
    "/Applications/DSH.app/Contents/Resources/app/dsh/node_modules/@deepseek-ai" \
    "$HOME/Applications/DSH.app/Contents/Resources/app/dsh/node_modules/@deepseek-ai"
  do
    if [ -d "${candidate}/schemastery" ]; then DSH_MODULES="$candidate"; break; fi
  done
fi
if [ -z "$DSH_MODULES" ] || [ ! -d "${DSH_MODULES}/schemastery" ]; then
  echo "Could not locate DSH's @deepseek-ai packages. Set DSH_NODE_MODULES=<path>." >&2
  exit 1
fi

echo "[1/3] plugin:  $PLUGIN_DIR"
echo "[2/3] modules: $DSH_MODULES"

rm -rf "${VENDOR:?}/lib"
mkdir -p "${VENDOR}"
cp -R "${PLUGIN_DIR}/lib" "${VENDOR}/lib"
cp "${PLUGIN_DIR}/package.json" "${VENDOR}/package.json"

echo "[3/3] linking runtime dependencies"
LINK_ROOT="${VENDOR}/node_modules/@deepseek-ai"
mkdir -p "$LINK_ROOT"
for pkg in "${PACKAGES[@]}"; do
  rm -rf "${LINK_ROOT:?}/${pkg}"
  ln -s "${DSH_MODULES}/${pkg}" "${LINK_ROOT}/${pkg}"
  echo "      link $pkg"
done

node --input-type=module -e "
const mod = await import('${VENDOR}/lib/index.mjs')
const required = ['CodeArtsAccountStore','CodeArtsCatalog','createCodeArtsShim','refreshCatalog','codeartsAccountsPath','codeartsAuthPath']
const missing = required.filter((name) => mod[name] === undefined)
if (missing.length > 0) { console.error('missing exports: ' + missing.join(', ')); process.exit(1) }
console.log('      bundle OK')
"

echo ""
echo "done. next: node src/gateway.mjs"
