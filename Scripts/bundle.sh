#!/usr/bin/env bash
# Builds and signs .build/PBSMackup.app: the menu bar app, the run tool, the launchd job and the
# client. The client is the one built in a checkout of the fork next to this one
# (../proxmox-backup-macos), from exactly the commit in client.commit; PBS_MACKUP_CLIENT names another
# binary and skips that check.
#
#   PBS_MACKUP_SIGN_IDENTITY   signing identity, "Developer ID Application" when not set
#   PBS_MACKUP_BUNDLE_ID       bundle identifier; also the Keychain service and, with .run, the launchd job
#   PBS_MACKUP_VERSION         version, the content of VERSION when not set
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${PBS_MACKUP_SIGN_IDENTITY:-Developer ID Application}"
id="${PBS_MACKUP_BUNDLE_ID:-me.0x23.pbs-mackup}"
version="${PBS_MACKUP_VERSION:-$(cat VERSION)}"
client="${PBS_MACKUP_CLIENT:-../proxmox-backup-macos/native-target/release/proxmox-backup-client}"
[ -x "$client" ] || { echo "no client at $client" >&2; exit 1; }
if [ -z "${PBS_MACKUP_CLIENT:-}" ]; then
    pinned="$(tr -d '[:space:]' < client.commit)"
    built="$(env -u PBS_REPOSITORY "$client" version --output-format json | sed -n 's/.*"repoid":"\([^"]*\)".*/\1/p')"
    [ "$built" = "$pinned" ] || {
        echo "the client is built from ${built:-an unknown commit}, the app is pinned to $pinned" >&2
        echo "check out that commit in ../proxmox-backup-macos and run 'just build' there, or update client.commit" >&2
        exit 1
    }
fi
# The app has to run on a Mac without Homebrew: the client may load what macOS ships and,
# when it is there, FUSE-T's library, nothing else.
foreign="$(otool -L "$client" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@rpath/libfuse3' || true)"
[ -z "$foreign" ] || { echo "the client loads libraries a Mac does not have by itself:" >&2; echo "$foreign" >&2; exit 1; }

swift build -c release
bin="$(swift build -c release --show-bin-path)"
app=".build/PBSMackup.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
cp "$bin/PBSMackup" "$bin/pbs-mackup-run" "$app/Contents/MacOS/"
cp "$client" "$app/Contents/Helpers/proxmox-backup-client"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp LICENSE THIRD_PARTY.md "$app/Contents/Resources/"

# macOS 26: the client carries Homebrew's OpenSSL, which is built for that version.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${id}</string>
  <key>CFBundleName</key><string>PBS Mackup</string>
  <key>CFBundleExecutable</key><string>PBSMackup</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>BSD-3-Clause. The client inside is AGPL-3.0, from Proxmox Backup. Not a Proxmox product.</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# launchd starts the run tool every five minutes; it backs up when the interval from the
# settings is over, and otherwise ends at once.
cat > "$app/Contents/Library/LaunchAgents/${id}.run.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.run</string>
  <key>BundleProgram</key><string>Contents/MacOS/pbs-mackup-run</string>
  <key>StartInterval</key><integer>300</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityBackgroundIO</key><true/>
</dict></plist>
PLIST

# Everything gets the hardened runtime, which notarization asks for. The client may load
# FUSE-T's library, which another developer signed, so it alone is exempt from library
# validation.
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.client" \
    --entitlements Scripts/client.entitlements "$app/Contents/Helpers/proxmox-backup-client"
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.run" "$app/Contents/MacOS/pbs-mackup-run"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "built $app ($version, $id)"
