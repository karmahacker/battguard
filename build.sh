#!/bin/bash
# Build lidguard next to its source (swiftc from Xcode / Command Line Tools). No root needed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
swiftc -O -o "$HERE/lidguard" "$HERE/lidguard.swift"
echo "built $HERE/lidguard"
