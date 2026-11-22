#!/bin/zsh
set -eu
cd "${0:A:h}/.."
source_dir="$PWD"
test_dir="${1:?Usage: Tests/run-notes.sh /absolute/test-output-directory}"
mkdir -p "$test_dir/Test.app/Contents/MacOS"
app="$test_dir/Test.app"
ditto --norsrc --noextattr Resources "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.wenyi.notescheck "$app/Contents/Info.plist"
clang -c Sources/PTY.c -o "$test_dir/pty.o"
swiftc -D READER_TEST -swift-version 5 -import-objc-header Sources/PTY.h Sources/*.swift Tests/NotesSmoke.swift "$test_dir/pty.o" -o "$app/Contents/MacOS/WenyiReader"
"$app/Contents/MacOS/WenyiReader" "$test_dir" "${2:-}"
