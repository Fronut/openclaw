#!/usr/bin/env bash
set -euo pipefail

on_error() {
  echo "A2UI bundling failed. Re-run with: pnpm canvas:a2ui:bundle" >&2
  echo "If this persists, verify pnpm deps and try again." >&2
}
trap on_error ERR

# Resolve repo root in POSIX form for bash/WSL; keep optional Windows form for tooling that needs it.
ROOT_DIR_POSIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v wslpath >/dev/null 2>&1; then
  ROOT_DIR_WIN="$(wslpath -w "$ROOT_DIR_POSIX")"
elif ROOT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W 2>/dev/null)"; then
  ROOT_DIR_WIN="$ROOT_DIR_TMP"
fi
ROOT_DIR="$ROOT_DIR_POSIX"
HASH_FILE="$ROOT_DIR_POSIX/src/canvas-host/a2ui/.bundle.hash"
OUTPUT_FILE="$ROOT_DIR_POSIX/src/canvas-host/a2ui/a2ui.bundle.js"
A2UI_RENDERER_DIR="$ROOT_DIR_POSIX/vendor/a2ui/renderers/lit"
A2UI_APP_DIR="$ROOT_DIR_POSIX/apps/shared/OpenClawKit/Tools/CanvasA2UI"
HASH_ROOT="${ROOT_DIR_WIN:-$ROOT_DIR_POSIX}"

# Docker builds exclude vendor/apps via .dockerignore.
# In that environment we must keep the prebuilt bundle.
if [[ ! -d "$A2UI_RENDERER_DIR" || ! -d "$A2UI_APP_DIR" ]]; then
  echo "A2UI sources missing; keeping prebuilt bundle."
  exit 0
fi

INPUT_PATHS=(
  "$HASH_ROOT/package.json"
  "$HASH_ROOT/pnpm-lock.yaml"
  "$HASH_ROOT/vendor/a2ui/renderers/lit"
  "$HASH_ROOT/apps/shared/OpenClawKit/Tools/CanvasA2UI"
)

is_wsl() {
  [[ -f /proc/version ]] && grep -qi microsoft /proc/version
}

run_pnpm() {
  if is_wsl && command -v cmd.exe >/dev/null 2>&1; then
    local converted=()
    for arg in "$@"; do
      if [[ "$arg" == /* || "$arg" == .*/* || "$arg" == ~/* ]]; then
        if conv="$(wslpath -w "$arg" 2>/dev/null)"; then
          converted+=("$conv")
        else
          converted+=("$arg")
        fi
      else
        converted+=("$arg")
      fi
    done
    cmd.exe /c pnpm "${converted[@]}"
  else
    pnpm "$@"
  fi
}

run_rolldown() {
  if is_wsl && command -v cmd.exe >/dev/null 2>&1; then
    local converted=()
    for arg in "$@"; do
      if [[ "$arg" == /* || "$arg" == .*/* || "$arg" == ~/* ]]; then
        if conv="$(wslpath -w "$arg" 2>/dev/null)"; then
          converted+=("$conv")
        else
          converted+=("$arg")
        fi
      else
        converted+=("$arg")
      fi
    done
    cmd.exe /c rolldown "${converted[@]}"
  else
    rolldown "$@"
  fi
}

compute_hash() {
  HASH_ROOT="$HASH_ROOT" node --input-type=module - "${INPUT_PATHS[@]}" <<'NODE'
import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";

const rootDir = process.env.HASH_ROOT ?? process.cwd();
const inputs = process.argv.slice(2);
const files = [];

async function walk(entryPath) {
  const st = await fs.stat(entryPath);
  if (st.isDirectory()) {
    const entries = await fs.readdir(entryPath);
    for (const entry of entries) {
      await walk(path.join(entryPath, entry));
    }
    return;
  }
  files.push(entryPath);
}

for (const input of inputs) {
  await walk(input);
}

function normalize(p) {
  return p.split(path.sep).join("/");
}

files.sort((a, b) => normalize(a).localeCompare(normalize(b)));

const hash = createHash("sha256");
for (const filePath of files) {
  const rel = normalize(path.relative(rootDir, filePath));
  hash.update(rel);
  hash.update("\0");
  hash.update(await fs.readFile(filePath));
  hash.update("\0");
}

process.stdout.write(hash.digest("hex"));
NODE
}

current_hash="$(compute_hash)"
if [[ -f "$HASH_FILE" ]]; then
  previous_hash="$(cat "$HASH_FILE")"
  if [[ "$previous_hash" == "$current_hash" && -f "$OUTPUT_FILE" ]]; then
    echo "A2UI bundle up to date; skipping."
    exit 0
  fi
fi

run_pnpm -s exec tsc -p "$A2UI_RENDERER_DIR/tsconfig.json"
run_rolldown -c "$A2UI_APP_DIR/rolldown.config.mjs"

echo "$current_hash" > "$HASH_FILE"
