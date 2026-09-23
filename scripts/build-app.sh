#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/AI Quota.app"
icon_source="${project_dir}/Assets/ai-quota-icon.png"
iconset_dir="${project_dir}/.build/AIQuota.iconset"
icon_file="${app_dir}/Contents/Resources/AIQuota.icns"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/AIQuota" "$app_dir/Contents/MacOS/AIQuota"

if [[ -f "$icon_source" ]]; then
  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"
  sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset_dir" -o "$icon_file"
fi

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AIQuota</string>
  <key>CFBundleIdentifier</key><string>com.local.ai-quota</string>
  <key>CFBundleIconFile</key><string>AIQuota</string>
  <key>CFBundleName</key><string>AI Quota</string>
  <key>CFBundleDisplayName</key><string>AI Quota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

open "$app_dir"
