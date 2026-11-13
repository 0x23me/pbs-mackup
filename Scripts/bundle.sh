#!/usr/bin/env bash
# Builds and signs .build/PBSMackup.app: the menu bar app, the run tool, the launchd jobs and the
# client, twice. The client is the one built in a checkout of the fork next to this one
# (../proxmox-backup-macos), from exactly the commit in client.commit; PBS_MACKUP_CLIENT names another
# binary and skips that check.
#
#   PBS_MACKUP_SIGN_IDENTITY   signing identity, "Developer ID Application" when not set
#   PBS_MACKUP_BUNDLE_ID       bundle identifier; the run tool, the clients, the Keychain service and the
#                              launchd jobs are named after it
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
# The client is there twice. The first does every backup, listing and restore. It has no folder
# to look for FUSE-T's library in, so it loads nothing but what macOS ships. The second is only
# for "Open in Finder", which needs that library.
helpers="$app/Contents/Helpers"
cp "$client" "$helpers/proxmox-backup-client"
cp "$client" "$helpers/proxmox-backup-client-mount"
otool -l "$client" | awk '$1 == "cmd" { rpath = $2 == "LC_RPATH" } rpath && $1 == "path" { print $2 }' | while read -r folder; do
    install_name_tool -delete_rpath "$folder" "$helpers/proxmox-backup-client"
done
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

# Three launchd jobs, all the run tool. Their names stay with the name the run tool is signed as:
# launchd remembers for a job's name which program it may start and does not learn another, so
# a run tool under a new name needs jobs under new names (before 0.2 there was one job, ".run").
# `scheduled`: launchd starts it every five minutes; it backs up
# when the interval from the settings is over, and otherwise ends at once. As a background job
# it gets the slow cores and throttled disk and network, and so does the client it starts, which
# is right for a backup nobody is waiting for.
agents="$app/Contents/Library/LaunchAgents"
cat > "$agents/${id}.scheduled.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.scheduled</string>
  <key>BundleProgram</key><string>Contents/MacOS/pbs-mackup-run</string>
  <key>StartInterval</key><integer>300</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityBackgroundIO</key><true/>
</dict></plist>
PLIST
# The job of the versions before 0.2, which launchd no longer starts. It is never registered
# again; it is here because the app can only take a job away whose description it still has.
cat > "$agents/${id}.run.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.run</string>
  <key>BundleProgram</key><string>Contents/MacOS/pbs-mackup-run</string>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
PLIST
# `manual`: a backup the owner asked for with Back Up Now. Not a background job: the owner waits
# for it, and on a fast network a background job reaches a fraction of the speed.
cat > "$agents/${id}.manual.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.manual</string>
  <key>BundleProgram</key><string>Contents/MacOS/pbs-mackup-run</string>
  <key>ProgramArguments</key><array><string>pbs-mackup-run</string><string>--manual</string></array>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
# `helper`: what the app talks to for everything that needs the token or the key. launchd starts
# it when the app connects; it takes messages from the app alone.
cat > "$agents/${id}.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/pbs-mackup-run</string>
  <key>ProgramArguments</key><array><string>pbs-mackup-run</string><string>serve</string></array>
  <key>MachServices</key><dict><key>${id}.helper</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

# A run mounts its snapshot in the app's group container, where macOS asks the owner before it
# lets another developer's program in; the files a run restores to check them and a new key on
# its way into the Keychain go there too. The app, the run tool and the clients say that the
# folder is theirs, so they are let in without a question. Its name begins with the developer's
# Team ID, which a first signature tells; an ad-hoc signature names none, and such a build keeps
# all of that in the cache.
codesign --force --sign "$identity" "$helpers/proxmox-backup-client"
team="$(codesign -dv "$helpers/proxmox-backup-client" 2>&1 | sed -n 's/^TeamIdentifier=\([A-Z0-9]*\)$/\1/p')"
groups=""
group=""
mount="--entitlements Scripts/client.entitlements"
if [ -n "$team" ]; then
    groups="<key>com.apple.security.application-groups</key><array><string>${team}.${id}</string></array>"
    group="--entitlements .build/groups.entitlements"
    mount="--entitlements .build/mount.entitlements"
fi
for name in groups mount; do
    library=""
    [ "$name" = mount ] && library="<key>com.apple.security.cs.disable-library-validation</key><true/>"
    cat > ".build/$name.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  ${groups}
  ${library}
</dict></plist>
PLIST
done
# Everything gets the hardened runtime, which notarization asks for, and with it library
# validation: macOS lets a program load only libraries of its own developer and Apple's. The
# client for "Open in Finder" loads FUSE-T's library, which another developer signed, so it
# alone is exempt (Scripts/client.entitlements says what that exemption is).
# $group and $mount are two words or none.
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.client" $group "$helpers/proxmox-backup-client"
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.client-mount" $mount "$helpers/proxmox-backup-client-mount"
# The run tool signs as ".tool". The Keychain knows the program that may read the token and the
# key by this name and the developer, not by its version: every run tool ever released under
# this name can read them for good. The versions before 0.2 signed as ".run" and handed the key
# to whoever asked, which is why the name changed; it must not be given to a tool that does.
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.tool" $group "$app/Contents/MacOS/pbs-mackup-run"
codesign --force --options runtime --timestamp --sign "$identity" $group "$app"
codesign --verify --deep --strict "$app"
echo "built $app ($version, $id)"
