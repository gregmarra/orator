#!/usr/bin/env bash
# Regenerate the Liquid Glass app icon from source (macOS 26+, no Icon Composer GUI needed).
#
# Draws the orange waveform glyph, assembles Resources/AppIcon.icon (icon.json + Assets/), and
# compiles it with `actool` into Assets.car (the layered Liquid Glass asset) + a fallback
# AppIcon.icns. Both compiled outputs are written to Resources/ and shipped by bundle.sh.
#
# actool (ibtoold) crashes intermittently when pointed at a path inside the repo, so we compile in
# a fresh temp directory and copy the results back.
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_DIR="Resources/AppIcon.icon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Draw the waveform glyph (transparent PNG; the .icon background layer supplies the dark fill).
mkdir -p "$ICON_DIR/Assets"
cat > "$TMP/draw.swift" <<'SWIFT'
import AppKit
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1.0).setFill()
let heights: [Double] = [0.34, 0.58, 0.82, 1.0, 0.70, 0.52, 0.36]
let barW = 66.0, gap = 42.0, maxH = 600.0
let totalW = Double(heights.count) * barW + Double(heights.count - 1) * gap
var x = (size - totalW) / 2.0
for h in heights {
    let barH = maxH * h
    let r = NSRect(x: x, y: size/2 - barH/2, width: barW, height: barH)
    NSBezierPath(roundedRect: r, xRadius: barW/2, yRadius: barW/2).fill()
    x += barW + gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift "$TMP/draw.swift" "$ICON_DIR/Assets/waveform.png"

# 2. Compile the .icon in a clean temp dir, then copy the outputs back into Resources/.
#    ibtoold crashes intermittently, so retry until Assets.car appears (or give up after N tries).
cp -R "$ICON_DIR" "$TMP/AppIcon.icon"
ok=""
for attempt in 1 2 3 4 5; do
  rm -rf "$TMP/out"; mkdir -p "$TMP/out"
  ( cd "$TMP" && xcrun actool AppIcon.icon --compile out --app-icon AppIcon --include-all-app-icons \
      --target-device mac --platform macosx --minimum-deployment-target 26.0 \
      --output-partial-info-plist out/p.plist >/dev/null 2>&1 ) || true
  if [ -f "$TMP/out/Assets.car" ]; then ok=1; break; fi
  echo "actool attempt $attempt crashed (ibtoold); retrying…"
done
[ -n "$ok" ] || { echo "actool failed after retries; Resources/ assets left unchanged." >&2; exit 1; }
cp "$TMP/out/Assets.car" Resources/Assets.car
cp "$TMP/out/AppIcon.icns" Resources/AppIcon.icns
echo "Regenerated Resources/Assets.car + Resources/AppIcon.icns from $ICON_DIR"
