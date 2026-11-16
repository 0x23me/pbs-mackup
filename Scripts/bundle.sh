#!/usr/bin/env bash
# Builds and signs .build/PBSMackup.app: the menu bar app, the run tool, the launchd jobs and the
# client. The client is the one built in a checkout of the fork next to this one
# (../proxmox-backup-macos), from exactly the commit in client.commit; PBS_MACKUP_CLIENT names another
# binary and skips that check.
#
#   PBS_MACKUP_SIGN_IDENTITY   signing identity, "Developer ID Application" when not set
#   PBS_MACKUP_BUNDLE_ID       bundle identifier; the run tool, the client, the Keychain service and the
#                              launchd jobs are named after it
#   PBS_MACKUP_VERSION         version, the content of VERSION when not set
#   PBS_MACKUP_RUN_TOOL_PROFILE  a Developer ID provisioning profile for the run tool, for the
#                              identifier <bundle identifier>.tool with Keychain Sharing. With it the
#                              run tool gets a bundle of its own inside the app and keeps the token
#                              and the key in the data protection keychain, where no other
#                              developer's program reaches them. Without it the run tool lies next to
#                              the app and keeps them in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${PBS_MACKUP_SIGN_IDENTITY:-Developer ID Application}"
id="${PBS_MACKUP_BUNDLE_ID:-me.0x23.pbs-mackup}"
version="${PBS_MACKUP_VERSION:-$(cat VERSION)}"
profile="${PBS_MACKUP_RUN_TOOL_PROFILE:-}"
[ -z "$profile" ] || [ -f "$profile" ] || { echo "no provisioning profile at $profile" >&2; exit 1; }
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
# The app has to run on a Mac without Homebrew: the client may load what macOS ships, nothing
# else, and has no folder to look for libraries in.
foreign="$(otool -L "$client" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/' || true)"
[ -z "$foreign" ] || { echo "the client loads libraries a Mac does not have by itself:" >&2; echo "$foreign" >&2; exit 1; }
! otool -l "$client" | grep -q LC_RPATH || { echo "the client has a library search path" >&2; exit 1; }

swift build -c release
bin="$(swift build -c release --show-bin-path)"
app=".build/PBSMackup.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents" "$app/Contents/Library/LaunchDaemons"
cp "$bin/PBSMackup" "$app/Contents/MacOS/"
helpers="$app/Contents/Helpers"
cp "$client" "$helpers/proxmox-backup-client"
# The run tool. macOS lets a program into a keychain access group only when a provisioning
# profile says so, and looks for the profile in the bundle the program is the main program of.
# So with a profile the run tool gets a bundle of its own inside the app, with the profile in
# it. launchd starts it there; Contents/MacOS/pbs-mackup-run, the path the owner types at a
# terminal, becomes a link to it, and a tool started through the link is the same program with
# the same rights. Without a profile the run tool lies in Contents/MacOS itself.
if [ -n "$profile" ]; then
    run="$helpers/PBSMackupRun.app"
    program="Contents/Helpers/PBSMackupRun.app/Contents/MacOS/pbs-mackup-run"
    mkdir -p "$run/Contents/MacOS"
    cp "$bin/pbs-mackup-run" "$run/Contents/MacOS/"
    cp "$profile" "$run/Contents/embedded.provisionprofile"
    ln -s "../Helpers/PBSMackupRun.app/Contents/MacOS/pbs-mackup-run" "$app/Contents/MacOS/pbs-mackup-run"
    # Its identifier is the one the run tool is signed as and the profile is for.
    cat > "$run/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${id}.tool</string>
  <key>CFBundleName</key><string>PBS Mackup</string>
  <key>CFBundleExecutable</key><string>pbs-mackup-run</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
else
    run="$app/Contents/MacOS/pbs-mackup-run"
    program="Contents/MacOS/pbs-mackup-run"
    cp "$bin/pbs-mackup-run" "$run"
fi
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
  <key>NSAppleEventsUsageDescription</key><string>PBS Mackup records the apps that open at login with each backup and adds them back after a restore, and logs you out at the end of a restore from a backup, so that your restored home folder can take the place of this one.</string>
</dict></plist>
PLIST

# Three launchd jobs, all the run tool, where it lies in the app ($program). Their names stay with
# the name the run tool is signed as:
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
  <key>BundleProgram</key><string>${program}</string>
  <key>StartInterval</key><integer>300</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityBackgroundIO</key><true/>
</dict></plist>
PLIST
# `manual`: a backup the owner asked for with Back Up Now. Not a background job: the owner waits
# for it, and on a fast network a background job reaches a fraction of the speed.
cat > "$agents/${id}.manual.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.manual</string>
  <key>BundleProgram</key><string>${program}</string>
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
  <key>BundleProgram</key><string>${program}</string>
  <key>ProgramArguments</key><array><string>pbs-mackup-run</string><string>serve</string></array>
  <key>MachServices</key><dict><key>${id}.helper</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

# `restore`: the run tool as root, which restores a whole home folder for the app and lets it
# take the place of the owner's once they log out. The app registers it only while the owner
# restores this Mac from a backup, and takes it away after. launchd starts it at boot too, so
# that a restore that waits for the logout keeps waiting after a restart.
cat > "$app/Contents/Library/LaunchDaemons/${id}.restore.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${id}.restore</string>
  <key>BundleProgram</key><string>${program}</string>
  <key>ProgramArguments</key><array><string>pbs-mackup-run</string><string>restore-daemon</string></array>
  <key>MachServices</key><dict><key>${id}.restore</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>AssociatedBundleIdentifiers</key><array><string>${id}</string></array>
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
if [ -n "$team" ]; then
    groups="<key>com.apple.security.application-groups</key><array><string>${team}.${id}</string></array>"
    group="--entitlements .build/groups.entitlements"
fi
# The profile has to be for this run tool: macOS ends a program at once that says it is in a
# keychain access group and has no profile that agrees, so a profile that does not fit is found
# out here and not on the owner's Mac.
tool_group="$group"
if [ -n "$profile" ]; then
    wrong() { echo "the provisioning profile $profile $1" >&2; exit 1; }
    [ -n "$team" ] || wrong "needs a developer's signing identity, and \"$identity\" names no team"
    security cms -D -i "$profile" > .build/profile.plist 2>/dev/null || wrong "cannot be read"
    entitlement() { /usr/libexec/PlistBuddy -c "Print :Entitlements:$1" .build/profile.plist 2>/dev/null || true; }
    made_for="$(entitlement com.apple.application-identifier)"
    [ "$made_for" = "${team}.${id}.tool" ] || wrong "is for ${made_for:-nothing}, the run tool is ${team}.${id}.tool"
    entitlement keychain-access-groups | sed 's/^ *//' | grep -q -x -F -e "${team}.*" -e "${team}.${id}" \
        || wrong "does not allow the keychain access group ${team}.${id}"
    [ "$(plutil -extract ExpirationDate raw -o - .build/profile.plist)" \> "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ] || wrong "has expired"
    # It names the certificates it goes with; the one that signs has to be among them.
    rm -f .build/signer-*
    codesign -d --extract-certificates=.build/signer- "$helpers/proxmox-backup-client" 2>/dev/null
    signer="$(base64 -i .build/signer-0)"
    named=""
    for ((n = 0; n < $(plutil -extract DeveloperCertificates raw -o - .build/profile.plist); n++)); do
        [ "$(plutil -extract "DeveloperCertificates.$n" raw -o - .build/profile.plist)" != "$signer" ] || named=yes
    done
    [ -n "$named" ] || wrong "does not go with the certificate of \"$identity\""
    tool_group="--entitlements .build/tool.entitlements"
fi
for name in groups tool app; do
    more=""
    # The app sends Apple events: Log Out at the end of a restore, to loginwindow, and login items, to
    # System Events. The run tool reads login items too; macOS counts it as the app's, so it needs no entitlement.
    [ "$name" = app ] && more="<key>com.apple.security.automation.apple-events</key><true/>"
    # The run tool with a profile says which program of which developer it is, as the profile
    # has it, and is in the keychain access group the token and the key are kept in
    # (`Keychain.place`). Nothing else in the app is in that group, the app itself included.
    [ "$name" = tool ] && [ -n "$profile" ] && more="<key>com.apple.application-identifier</key><string>${team}.${id}.tool</string>
  <key>com.apple.developer.team-identifier</key><string>${team}</string>
  <key>keychain-access-groups</key><array><string>${team}.${id}</string></array>"
    cat > ".build/$name.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  ${groups}
  ${more}
</dict></plist>
PLIST
done
# Everything gets the hardened runtime, which notarization asks for, and with it library
# validation: macOS lets a program load only libraries of its own developer and Apple's.
# $group is two words or none.
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.client" $group "$helpers/proxmox-backup-client"
# The run tool signs as ".tool". The login keychain knows the program that may read the token
# and the key by this name and the developer, not by its version: every run tool ever released
# under this name can read what is kept there for good, which is why a run tool with a profile
# keeps nothing there. The versions before 0.2 signed as ".run" and handed the key to whoever
# asked, which is why the name changed; it must not be given to a tool that does. The profile
# and the launchd jobs go by this name too. $run is the run tool, or the bundle it is in: what
# is inside the app is signed before the app.
codesign --force --options runtime --timestamp --sign "$identity" -i "${id}.tool" $tool_group "$run"
app_entitlements="--entitlements .build/app.entitlements"
codesign --force --options runtime --timestamp --sign "$identity" $app_entitlements "$app"
codesign --verify --deep --strict "$app"
if [ -n "$profile" ]; then
    # macOS starts the run tool with what it asks for, also through the link. A word it does
    # not know has it print how it is used (64) and touch nothing.
    status=0
    "$app/Contents/MacOS/pbs-mackup-run" usage > /dev/null 2>&1 || status=$?
    [ "$status" = 64 ] || { echo "the run tool does not start with its provisioning profile ($status)" >&2; exit 1; }
    echo "built $app ($version, $id; the run tool keeps its secrets in the data protection keychain)"
else
    echo "built $app ($version, $id; the run tool keeps its secrets in the login keychain)"
fi
