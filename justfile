# pbs-mackup task runner. Run `just` to list recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Build all products (debug)
build:
    swift build

# Run unit tests
test:
    swift test

# Also the run tool's tests that take and mount real APFS snapshots (needs Full Disk Access for this terminal)
test-snapshots:
    PBS_MACKUP_SNAPSHOT_TESTS=1 swift test

# Build and sign .build/PBSMackup.app with the run tool, the launchd job and the client
bundle:
    ./Scripts/bundle.sh

# Bundle, then start the menu bar app (quits a running copy first)
run: bundle
    pkill -x PBSMackup || true
    open .build/PBSMackup.app

# Bundle, copy the app to /Applications and start it from there
install: bundle
    pkill -x PBSMackup || true
    rm -rf /Applications/PBSMackup.app
    ditto .build/PBSMackup.app /Applications/PBSMackup.app
    open /Applications/PBSMackup.app

# Build, sign and notarize a release into dist/, with its Homebrew cask: just release 0.1.0
release version:
    ./Scripts/release.sh {{version}}

# Redraw Resources/AppIcon.icns
icon:
    swift Scripts/icon.swift

# One backup run from this terminal, started by hand
backup:
    .build/PBSMackup.app/Contents/MacOS/pbs-mackup-run --manual
