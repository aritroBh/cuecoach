#!/bin/sh
# Assemble offline, pinned Swift package sources for CueVLMBench into tools/vlm-bench/Vendor (gitignored).
#
# Why: SwiftPM git mirrors of mlx-swift (with its mlx / mlx-c submodules) and swift-transformers' transitive
# deps (swift-huggingface, swift-xet, swift-crypto, yyjson, EventSource...) are slow to clone and phone-home
# capable. We pin source tarballs and trim swift-transformers to Tokenizers + an offline HubApi
# (vendor-patches/HubApiLite.swift), so the bench app has no network code path at all.
#
# Usage: ./vendor.sh [download-cache-dir]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
V="$here/Vendor"
DL=${1:-"$V/_dl"}
mkdir -p "$V" "$DL"

MLX_SWIFT_LM=3.31.4
MLX_SWIFT=0.31.4
MLX_COMMIT=ce45c52505c8158ea48d2a54e8caae05efd86bfe     # mlx-swift 0.31.4 submodule Source/Cmlx/mlx
MLXC_COMMIT=0726ca922fc902c4c61ef9c27d94132be418e945    # mlx-swift 0.31.4 submodule Source/Cmlx/mlx-c
NUMERICS=1.1.1
TRANSFORMERS=1.4.0
JINJA=2.5.2
COLLECTIONS=1.1.4

fetch() { # url file
  [ -s "$DL/$2" ] || curl -sSL --retry 3 -o "$DL/$2" "$1"
}
fetch "https://codeload.github.com/ml-explore/mlx-swift-lm/tar.gz/refs/tags/$MLX_SWIFT_LM" mlx-swift-lm.tgz
fetch "https://codeload.github.com/ml-explore/mlx-swift/tar.gz/refs/tags/$MLX_SWIFT" mlx-swift.tgz
fetch "https://codeload.github.com/ml-explore/mlx/tar.gz/$MLX_COMMIT" mlx.tgz
fetch "https://codeload.github.com/ml-explore/mlx-c/tar.gz/$MLXC_COMMIT" mlxc.tgz
fetch "https://codeload.github.com/apple/swift-numerics/tar.gz/refs/tags/$NUMERICS" numerics.tgz
fetch "https://codeload.github.com/huggingface/swift-transformers/tar.gz/refs/tags/$TRANSFORMERS" st.tgz
fetch "https://codeload.github.com/huggingface/swift-jinja/tar.gz/refs/tags/$JINJA" jinja.tgz
fetch "https://codeload.github.com/apple/swift-collections/tar.gz/refs/tags/$COLLECTIONS" coll.tgz

x() { # tgz dest
  rm -rf "$V/$2" && mkdir -p "$V/$2" && tar xzf "$DL/$1" -C "$V/$2" --strip-components 1
}
x numerics.tgz swift-numerics
x coll.tgz swift-collections
x jinja.tgz swift-jinja
x mlx-swift.tgz mlx-swift
x mlx.tgz mlx-swift/Source/Cmlx/mlx
x mlxc.tgz mlx-swift/Source/Cmlx/mlx-c
x mlx-swift-lm.tgz mlx-swift-lm
x st.tgz _st

# Rewire remote package URLs to local paths.
sed -i '' 's#\.package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0")#.package(path: "../swift-collections")#' "$V/swift-jinja/Package.swift"
sed -i '' 's#\.package(url: "https://github.com/apple/swift-numerics", from: "1.0.0")#.package(path: "../swift-numerics")#' "$V/mlx-swift/Package.swift"
python3 - "$V/mlx-swift-lm/Package.swift" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'\.package\(url: "https://github.com/ml-explore/mlx-swift",[^\n]*\),', '.package(path: "../mlx-swift"),', s)
s = re.sub(r'\s*// 602\.0\.0 floor:.*?\n(\s*//.*\n)*\s*\.package\(url: "https://github.com/swiftlang/swift-syntax\.git"[^\n]*\n', '\n', s, flags=re.S)
# drop the HuggingFace macro integration (needs swift-syntax); we bridge tokenizers ourselves
s = re.sub(r'\s*\.library\(\s*name: "MLXHuggingFace",\s*targets: \["MLXHuggingFace"\]\),', '', s)
s = re.sub(r'\s*\.macro\(\s*name: "MLXHuggingFaceMacros".*?\n        \),', '', s, flags=re.S)
s = re.sub(r'\s*\.target\(\s*name: "MLXHuggingFace",.*?\n        \),', '', s, flags=re.S)
open(p, 'w').write(s)
PY

# swift-transformers-lite: Hub (offline) + Tokenizers only.
L="$V/swift-transformers-lite"
rm -rf "$L" && mkdir -p "$L/Sources"
cp -R "$V/_st/Sources/Tokenizers" "$L/Sources/"
mkdir -p "$L/Sources/Hub"
cp -R "$V/_st/Sources/Hub/Resources" "$V/_st/Sources/Hub/Config.swift" "$V/_st/Sources/Hub/BinaryDistinct.swift" \
  "$V/_st/Sources/Hub/Hub.swift" "$L/Sources/Hub/"
cp "$here/vendor-patches/HubApiLite.swift" "$L/Sources/Hub/"
rm -rf "$V/_st"
cat > "$L/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-transformers",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Tokenizers", targets: ["Tokenizers"])],
    dependencies: [
        .package(path: "../swift-jinja"),
        .package(path: "../swift-collections"),
    ],
    targets: [
        .target(name: "Hub", dependencies: [
            .product(name: "Jinja", package: "swift-jinja"),
            .product(name: "OrderedCollections", package: "swift-collections"),
        ], resources: [.process("Resources")]),
        .target(name: "Tokenizers", dependencies: ["Hub", .product(name: "Jinja", package: "swift-jinja")]),
    ]
)
SWIFT
echo "vendored into $V"
python3 "$here/vendor-patches/patch_mlx.py" "$V/mlx-swift"
python3 "$here/vendor-patches/patch_mlx_lm.py" "$V/mlx-swift-lm"
