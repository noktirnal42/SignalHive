#!/usr/bin/env bash
# Finds SF Symbol names that do not exist on this Mac. An invalid name does not fail to compile: it renders as a blank
# icon (this is how an empty Save button and several empty Workshop tiles shipped). Run on macOS.
#
#   script/check_sf_symbols.sh
#
# It reads the names used in `systemImage:`, `systemName:`, `symbol:` and the `icon`/`symbolName` properties, and asks
# AppKit whether each one resolves. Exit status 1 if any does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" > "$WORK/names.txt" <<'PY'
import glob, re, sys
root = sys.argv[1]
files = glob.glob(f"{root}/App/**/*.swift", recursive=True) + glob.glob(f"{root}/Packages/SignalHiveCore/Sources/**/*.swift", recursive=True)
name = r'"([a-z0-9]+(?:\.[a-z0-9]+)*)"'
direct = [
    r'systemImage:\s*(?:[^"\n]*\?\s*)?' + name + r'(?:\s*:\s*' + name + r')?',
    r'systemImageName:\s*' + name,
    r'systemName:\s*' + name,
    r'symbol:\s*' + name,
    r'^\s*\("[^"]+",\s*"[^"]+",\s*"[^"]*",\s*' + name + r'\)',   # WorkshopCatalog's (id, title, detail, symbol) rows
]
block = re.compile(r'var (?:icon|symbolName|symbol)\b[^{\n]*\{(.*?)\n    \}', re.S)
seen = set()
for path in sorted(files):
    text = open(path, encoding="utf-8").read()
    for pattern in direct:
        for m in re.finditer(pattern, text, re.M):
            seen.update((g, path) for g in m.groups() if g)
    for b in block.finditer(text):
        for m in re.finditer(r'return\s+' + name, b.group(1)):
            seen.add((m.group(1), path))
for n, p in sorted(seen):
    print(n, p.replace(root + "/", ""))
PY

cat > "$WORK/check.swift" <<'SWIFT'
import AppKit
import Foundation
let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var bad = 0
var names = Set<String>()
for line in text.split(separator: "\n") {
    let parts = line.split(separator: " ")
    let name = String(parts[0])
    names.insert(name)
    if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
        print("invalid SF Symbol \"\(name)\" in \(parts[1])")
        bad += 1
    }
}
print("checked \(names.count) distinct symbol names, \(bad) invalid")
exit(bad == 0 ? 0 : 1)
SWIFT

swift "$WORK/check.swift" "$WORK/names.txt"
