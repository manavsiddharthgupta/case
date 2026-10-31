#!/bin/zsh
# Builds Case for sharing: a Release build signed with the "Case Release" certificate in your
# keychain, zipped to build/Case.zip. Keep signing with that certificate: macOS ties permissions
# to it, so a new one makes everyone allow them all again.
set -e
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# The prefix maps and stripping keep this Mac's folder paths out of the app.
xcodebuild -project Case.xcodeproj -scheme Case -configuration Release -derivedDataPath build/dd \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=." OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$PWD=." \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global \
    build

app=build/dd/Build/Products/Release/Case.app
codesign --force --sign "Case Release" "$app"
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" build/Case.zip
echo "Built build/Case.zip"
