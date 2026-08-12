#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle_path="$repo_root/build/Codex Traffic Light.app"
executable_path="$repo_root/.build/release/CodexTrafficLightApp"
plist_path="$bundle_path/Contents/Info.plist"
version=${VERSION:-1.0.0}
build_number=${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}

case "$version" in
    ''|*[!0-9.]*|.*|*.)
        echo "VERSION must contain only numeric dot-separated components" >&2
        exit 1
        ;;
esac

case "$bundle_path" in
    "$repo_root/build/Codex Traffic Light.app") ;;
    *)
        echo "Refusing to replace unexpected bundle path: $bundle_path" >&2
        exit 1
        ;;
esac

swift build --package-path "$repo_root" -c release --product CodexTrafficLightApp

if [ -e "$bundle_path" ]; then
    /bin/rm -rf -- "$bundle_path"
fi

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$executable_path" "$bundle_path/Contents/MacOS/CodexTrafficLight"
chmod 755 "$bundle_path/Contents/MacOS/CodexTrafficLight"

plutil -create xml1 "$plist_path"
plutil -insert CFBundleExecutable -string CodexTrafficLight "$plist_path"
plutil -insert CFBundleIdentifier -string local.codex.traffic-light "$plist_path"
plutil -insert CFBundleName -string "Codex Traffic Light" "$plist_path"
plutil -insert CFBundlePackageType -string APPL "$plist_path"
plutil -insert CFBundleShortVersionString -string "$version" "$plist_path"
plutil -insert CFBundleVersion -string "$build_number" "$plist_path"
plutil -insert LSMinimumSystemVersion -string 13.0 "$plist_path"
plutil -insert LSUIElement -bool true "$plist_path"

echo "Created $bundle_path"
