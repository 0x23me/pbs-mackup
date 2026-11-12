#!/usr/bin/env bash
# Builds, signs and notarizes VERSION into dist/: PBSMackup-VERSION.zip, its SHA256, and the
# Homebrew cask for it (dist/pbs-mackup.rb, to copy into the tap's Casks folder).
# Notarization uses the notarytool keychain profile in PBS_MACKUP_NOTARY_PROFILE (default
# "pbs-mackup"), stored once with:
#   xcrun notarytool store-credentials pbs-mackup --apple-id ... --team-id ...
# PBS_MACKUP_REPOSITORY is the GitHub repository the zip will be attached to as release vVERSION.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: release.sh VERSION, as 0.1.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION is MAJOR.MINOR.PATCH, not $version" >&2; exit 1; }
profile="${PBS_MACKUP_NOTARY_PROFILE:-pbs-mackup}"
repository="${PBS_MACKUP_REPOSITORY:-0x23me/pbs-mackup}"
PBS_MACKUP_VERSION="$version" ./Scripts/bundle.sh
app=.build/PBSMackup.app
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
mkdir -p dist
zip="dist/PBSMackup-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
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

  uninstall launchctl: "$id.run",
            quit:      "$id"

  zap trash: [
    "~/Library/Application Support/pbs-mackup",
    "~/Library/Caches/pbs-mackup",
  ]

  caveats <<~EOS
    Switch on Full Disk Access for PBS Mackup in System Settings.
    Open in Finder needs FUSE-T: brew install --cask fuse-t
  EOS
end
CASK
echo "notarized: $zip"
echo "cask:      dist/pbs-mackup.rb"
