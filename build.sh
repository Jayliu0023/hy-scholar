#!/bin/zsh
set -eu
cd "${0:A:h}"
destination="${1:-$PWD/../Hy-translator.app}"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/Hy-translator.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -O2 -c Sources/PTY.c -o "$build_dir/pty.o"
swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 -import-objc-header Sources/PTY.h Sources/*.swift "$build_dir/pty.o" -o "$app/Contents/MacOS/HyTranslator"
cp -X Info.plist "$app/Contents/Info.plist"
ditto --norsrc --noextattr Resources "$app/Contents/Resources"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto --norsrc --noextattr "$app" "$destination"
if xattr -p com.apple.FinderInfo "$destination" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$destination"
fi
codesign --verify --strict "$destination"
