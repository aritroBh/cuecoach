// swift-tools-version: 6.2
// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Vendored into CueCoach from github.com/meta/astryx packages/native/apple (MIT, see LICENSE), commit
// 86fcdd3f0a9c46af063cc25c156382a30a2c9b42. CueCoach's changes (THIRD_PARTY_NOTICES.md at the repo root lists them): iOS 27 only,
// no external dependencies, the JavaScriptCore logic host, the wire view, Avatar, Thumbnail and the
// non-default themes left out, and every link (`href`) and remote image removed (CueCoach makes zero network calls).

import PackageDescription

let package = Package(
  name: "Astryx",
  defaultLocalization: "en",
  platforms: [.iOS("27.0")],
  products: [
    .library(name: "Astryx", targets: ["Astryx"]),
  ],
  targets: [
    // Contract types only (generated props and enums); no logic host, no wire.
    .target(name: "AstryxNative", path: "Sources/AstryxNative"),
    // Resources holds core's catalog messages per locale.
    .target(
      name: "Astryx",
      dependencies: ["AstryxNative"],
      path: "Sources/Astryx",
      resources: [.process("Resources")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
