#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
arm_build="$project_dir/.build-arm64"
intel_build="$project_dir/.build-x86_64"
# Candidate bundles are kept under a Spotlight-excluded directory. Leaving a
# second .app in an indexed Documents folder lets Launch Services rediscover
# it after the one-shot unregister in cleanup, which can create a misleading
# duplicate Launchpad item beside the installed copy.
dist_dir="$project_dir/dist.noindex"
app_path="$dist_dir/温衡.app"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/heatguard-build.XXXXXX")"
temporary_app="$temporary_root/温衡.app"
backup_app="$temporary_root/existing-温衡.app"
iconset="$temporary_root/AppIcon.iconset"

cleanup() {
    if [[ ! -e "$app_path" && -d "$backup_app" ]]; then
        /bin/mv "$backup_app" "$app_path"
    fi
    # Running the bundle's executable directly can cause Launch Services to
    # discover the build artifact again (for example during --self-test).
    # The dist.noindex copy is a candidate, not the installed product: leaving it
    # registered creates a second Launchpad entry and makes a double-click
    # look like an upgrade even though the installed PID is unchanged.
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [[ -x "$lsregister" && -d "$app_path" ]]; then
        # Launch Services may asynchronously rediscover a bundle just moved
        # into dist.noindex. Let that registration settle, then retry across the
        # remaining short window so a successful build does not leave a
        # duplicate Launchpad item behind.
        /bin/sleep 2
        for _ in {1..12}; do
            "$lsregister" -u "$app_path" >/dev/null 2>&1 || true
            /bin/sleep 1
        done
    fi
    rm -rf "$temporary_root"
}
trap cleanup EXIT

cd "$project_dir"
/usr/bin/swift Tools/GenerateIcon.swift "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$temporary_root/AppIcon.icns"

# Bound local compiler concurrency while the user's other work is running.
/usr/bin/swift build -j 2 -c release --arch arm64 --scratch-path "$arm_build"
/usr/bin/swift build -j 2 -c release --arch x86_64 --scratch-path "$intel_build"

mkdir -p "$temporary_app/Contents/MacOS" "$temporary_app/Contents/Resources"
/usr/bin/lipo -create \
    "$arm_build/arm64-apple-macosx/release/HeatGuard" \
    "$intel_build/x86_64-apple-macosx/release/HeatGuard" \
    -output "$temporary_app/Contents/MacOS/HeatGuard"
/bin/chmod 755 "$temporary_app/Contents/MacOS/HeatGuard"
/bin/cp "$project_dir/Resources/Info.plist" "$temporary_app/Contents/Info.plist"
/bin/cp "$temporary_root/AppIcon.icns" "$temporary_app/Contents/Resources/AppIcon.icns"
/bin/cp "$project_dir/THIRD_PARTY_NOTICES.md" "$temporary_app/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Keep the installed binary traceable to the exact local source tree. The
# manifest is inside the sealed bundle and is intentionally generated before
# signing; it contains no credentials or machine-specific paths.
source_sha="$(find "$project_dir/Sources" "$project_dir/Package.swift" "$project_dir/Resources/Info.plist" -type f -print0 2>/dev/null \
    | sort -z \
    | xargs -0 /usr/bin/shasum -a 256 \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}')"
binary_payload_sha="$(/usr/bin/shasum -a 256 "$temporary_app/Contents/MacOS/HeatGuard" | /usr/bin/awk '{print $1}')"
icon_sha="$(/usr/bin/shasum -a 256 "$temporary_app/Contents/Resources/AppIcon.icns" | /usr/bin/awk '{print $1}')"
{
    print -r -- "product=温衡 HeatGuard"
    print -r -- "version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$temporary_app/Contents/Info.plist")"
    print -r -- "build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$temporary_app/Contents/Info.plist")"
    print -r -- "source_tree_sha256=$source_sha"
    print -r -- "binary_payload_sha256=$binary_payload_sha"
    print -r -- "icon_sha256=$icon_sha"
    print -r -- "architectures=arm64,x86_64"
    print -r -- "built_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    print -r -- "signed=adhoc"
} > "$temporary_app/Contents/build-manifest.txt"
/bin/chmod 600 "$temporary_app/Contents/build-manifest.txt"

/usr/bin/plutil -lint "$temporary_app/Contents/Info.plist"
icon_name="$(/usr/bin/plutil -extract CFBundleIconName raw -o - "$temporary_app/Contents/Info.plist")"
[[ "$icon_name" == "AppIcon" && -s "$temporary_app/Contents/Resources/AppIcon.icns" ]]
# The executable payload hash above is intentionally captured before signing.
# macOS embeds its ad-hoc code signature inside the Mach-O and a recursive
# re-sign changes those bytes; the stable payload hash plus the final strict
# bundle verification are the meaningful release checks.
/usr/bin/codesign --force --deep --options runtime --sign - "$temporary_app"
/usr/bin/codesign --verify --deep --strict "$temporary_app"
"$temporary_app/Contents/MacOS/HeatGuard" --self-test

mkdir -p "$dist_dir"
if [[ -e "$app_path" ]]; then
    /bin/mv "$app_path" "$backup_app"
fi
/bin/mv "$temporary_app" "$app_path"

echo "Built: $app_path"
/usr/bin/file "$app_path/Contents/MacOS/HeatGuard"
