#!/bin/zsh
# Builds a new version of Case: ./release.sh 0.2
# It's signed with the "Case Release" certificate, and with Sparkle's "case" key, both in your
# keychain. Keep both: a new certificate makes everyone allow every permission again, and without
# the key nobody can update. Afterwards, upload everything in build/updates to the update site.
set -e
cd "$(dirname "$0")"

version=$1
[[ -n $version ]] || { echo "Usage: ./release.sh 0.2"; exit 1; }
[[ -z $CASE_DOWNLOADS ]] && CASE_DOWNLOADS=https://case.makeagent.studio/

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Sparkle updates when this number goes up, so it's the date and time.
build=$(date +%y%m%d%H%M)
# The prefix maps and stripping keep this Mac's folder paths out of the app.
xcodebuild -project Case.xcodeproj -scheme Case -configuration Release -derivedDataPath build/dd \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=." OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$PWD=." \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global \
    build

app=build/dd/Build/Products/Release/Case.app
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
# Inside out: each signature covers what's inside it.
for part in $sparkle/XPCServices/Installer.xpc $sparkle/XPCServices/Downloader.xpc \
    $sparkle/Autoupdate $sparkle/Updater.app $app/Contents/Frameworks/Sparkle.framework $app; do
    codesign --force --sign "Case Release" $part
done
codesign --verify --strict --deep $app

ditto -c -k --keepParent $app build/Case.zip
mkdir -p build/updates
cp build/Case.zip build/updates/Case-$version.zip
build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --account case \
    --download-url-prefix $CASE_DOWNLOADS build/updates
echo "Built Case $version: build/Case.zip, and build/updates for the update site"
