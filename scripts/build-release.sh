#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
cd "$root"

: "${EXPECTED_XCODE_BUILD:?Set EXPECTED_XCODE_BUILD to stable Xcode build ID}"
: "${EXPECTED_SDK_BUILD:?Set EXPECTED_SDK_BUILD to stable macOS SDK build ID}"
: "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY to owner/repository}"

developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == *beta* ]]; then
  print -u2 "Release requires stable Xcode, got: $developer_dir"
  exit 1
fi

xcode_build=$(xcodebuild -version | awk '/Build version/ { print $3 }')
if [[ "$xcode_build" != "$EXPECTED_XCODE_BUILD" ]]; then
  print -u2 "Expected Xcode build $EXPECTED_XCODE_BUILD, got $xcode_build"
  exit 1
fi

version=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" GlobeFlip/Info.plist)
work="$root/.release"
dist="$root/dist"
archive="$work/GlobeFlip.xcarchive"
app="$archive/Products/Applications/GlobeFlip.app"
artifact="$dist/GlobeFlip-$version-arm64.zip"

rm -rf "$work" "$dist"
mkdir -p "$work" "$dist"
xcodegen generate

xcodebuild archive \
  -project GlobeFlip.xcodeproj \
  -scheme GlobeFlip \
  -configuration Release \
  -archivePath "$archive" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_STYLE=Manual

codesign --verify --deep --strict "$app"
# Capture once: grep -q on a live pipe can SIGPIPE codesign under pipefail.
signature=$(codesign -dv "$app" 2>&1)
if [[ "$signature" != *$'\nSignature=adhoc'* ]]; then
  print -u2 "Release is not ad-hoc signed"
  exit 1
fi
if ! print -r -- "$signature" | grep '^CodeDirectory.*flags=.*runtime' >/dev/null; then
  print -u2 "Release is missing Hardened Runtime"
  exit 1
fi

entitlements=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
if [[ "$entitlements" == *com.apple.security.get-task-allow* ]]; then
  print -u2 "Release contains com.apple.security.get-task-allow"
  exit 1
fi

sdk_build=$(/usr/libexec/PlistBuddy \
  -c "Print :DTSDKBuild" "$app/Contents/Info.plist")
if [[ "$sdk_build" != "$EXPECTED_SDK_BUILD" ]]; then
  print -u2 \
    "Expected SDK build $EXPECTED_SDK_BUILD, got $sdk_build"
  exit 1
fi

if spctl -a -t exec -vv "$app" >/dev/null 2>&1; then
  print -u2 "Ad-hoc release unexpectedly passed Gatekeeper assessment"
  exit 1
fi

find "$app" -exec touch -h -t 202601010000 {} +
codesign --verify --deep --strict "$app"
(
  cd "$archive/Products/Applications"
  find GlobeFlip.app -print |
    LC_ALL=C sort |
    zip -X -y -q "$artifact" -@
)

checksum=$(shasum -a 256 "$artifact" | awk '{ print $1 }')
print "$checksum  ${artifact:t}" > "$artifact.sha256"

cat > "$dist/globeflip.rb" <<EOF
cask "globeflip" do
  version "$version"
  sha256 "$checksum"

  url "https://github.com/$GITHUB_REPOSITORY/releases/download/v#{version}/GlobeFlip-#{version}-arm64.zip"
  name "GlobeFlip"
  desc "Switch macOS Input Sources with a standalone Globe/Fn tap"
  homepage "https://github.com/$GITHUB_REPOSITORY"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "GlobeFlip.app"

  uninstall quit: "com.martyrer.GlobeFlip"

  zap trash: [
    "~/Library/Preferences/com.martyrer.GlobeFlip.plist",
  ]
end
EOF

print "Built $artifact"
print "SHA-256 $checksum"
