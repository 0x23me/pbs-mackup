#!/usr/bin/env bash
# Builds, signs and notarizes VERSION into dist/: PBSMackup-VERSION.zip, its SHA256, and the
# Homebrew cask for it (dist/pbs-mackup.rb, to copy into the tap's Casks folder).
# Notarization uses an App Store Connect API key when PBS_MACKUP_NOTARY_KEY names its .p8 file
# (with PBS_MACKUP_NOTARY_KEY_ID and PBS_MACKUP_NOTARY_ISSUER; this is how the release workflow
# runs it), and otherwise the notarytool keychain profile in PBS_MACKUP_NOTARY_PROFILE (default
# "pbs-mackup"), stored once with:
#   xcrun notarytool store-credentials pbs-mackup --apple-id ... --team-id ...
# PBS_MACKUP_REPOSITORY is the GitHub repository the zip will be attached to as release vVERSION.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: release.sh VERSION, as 0.1.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION is MAJOR.MINOR.PATCH, not $version" >&2; exit 1; }
if [ -n "${PBS_MACKUP_NOTARY_KEY:-}" ]; then
    notary=(--key "$PBS_MACKUP_NOTARY_KEY" --key-id "${PBS_MACKUP_NOTARY_KEY_ID:?}" --issuer "${PBS_MACKUP_NOTARY_ISSUER:?}")
else
    notary=(--keychain-profile "${PBS_MACKUP_NOTARY_PROFILE:-pbs-mackup}")
fi
repository="${PBS_MACKUP_REPOSITORY:-0x23me/pbs-mackup}"
PBS_MACKUP_VERSION="$version" ./Scripts/bundle.sh
app=.build/PBSMackup.app
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
# The app mounts its snapshots in the group container of the team that signed it.
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=\([A-Z0-9]*\)$/\1/p')"
[ -n "$team" ] || { echo "the app is not signed by a developer; a release has to be" >&2; exit 1; }
mkdir -p dist
zip="dist/PBSMackup-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" "${notary[@]}" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
rm "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(cd dist && shasum -a 256 "PBSMackup-$version.zip" > "PBSMackup-$version.zip.sha256")
sha="$(cut -d' ' -f1 "dist/PBSMackup-$version.zip.sha256")"

cat > dist/pbs-mackup.rb <<CASK
cask "pbs-mackup" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repository/releases/download/v#{version}/PBSMackup-#{version}.zip"
  name "PBS Mackup"
  desc "Home folder backups to a Proxmox Backup Server"
  homepage "https://github.com/$repository"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "PBSMackup.app"

  uninstall launchctl: ["$id.scheduled", "$id.manual", "$id.helper", "$id.run"],
            quit:      "$id"

  zap trash: [
    "~/Library/Application Support/pbs-mackup",
    "~/Library/Caches/pbs-mackup",
    "~/Library/Group Containers/$team.$id",
  ]

  caveats <<~EOS
    Switch on Full Disk Access for PBS Mackup in System Settings.
    Open in Finder needs FUSE-T: brew install --cask fuse-t
  EOS
end
CASK
echo "notarized: $zip"
echo "cask:      dist/pbs-mackup.rb"
