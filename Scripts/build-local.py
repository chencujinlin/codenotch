#!/usr/bin/env python3
"""Build a local macOS app with Command Line Tools, without a full Xcode install."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build" / "local-package"


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    # Only generated staging directories are replaced. Compiler caches survive.
    for name in ("Sources", "Tests"):
        target = WORK / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(ROOT / name, target)
    (WORK / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Codenotch", defaultLocalization: "en", platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", exact: "2.102.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "CZstd", path: "Sources/Vendor/zstd", exclude: ["README.md", "LICENSE"], publicHeadersPath: "."),
        .executableTarget(name: "Codenotch", dependencies: ["CZstd", "Sparkle",
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")],
            path: "Sources", exclude: ["Vendor", "Info.plist", "Assets.xcassets", "Localizable.xcstrings", "Codenotch-Bridging-Header.h"],
            resources: [.process("LocalResources"), .copy("Resources")]),
        .testTarget(name: "CodenotchTests", dependencies: ["Codenotch"], path: "Tests")
    ], swiftLanguageModes: [.v5])
''')
    # Preserve the upstream dependency pins; SwiftPM may only rewrite its staging copy.
    shutil.copy2(ROOT / "Package.resolved", WORK / "Package.resolved")
    catalog = json.loads((ROOT / "Sources/Localizable.xcstrings").read_text())
    languages = {"en"}
    for entry in catalog["strings"].values():
        languages.update(entry.get("localizations", {}))
    for language in languages:
        directory = WORK / "Sources/LocalResources" / (language + ".lproj")
        directory.mkdir(parents=True, exist_ok=True)
        entries = []
        for key, entry in catalog["strings"].items():
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
            value = unit.get("value", key)
            entries.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};')
        (directory / "Localizable.strings").write_text("\n".join(entries) + "\n")


def prepare_token_tests():
    WORK.mkdir(parents=True, exist_ok=True)
    for name in ("Sources", "Tests"):
        target = WORK / name
        if target.exists():
            shutil.rmtree(target)
        target.mkdir()
    for name in ("DailyTokenUsage.swift", "DailyTokenStore.swift", "TokenCountFormat.swift"):
        shutil.copy2(ROOT / "Sources/Model" / name, WORK / "Sources" / name)
    shutil.copy2(ROOT / "Tests/DailyTokenUsageTests.swift", WORK / "Tests/DailyTokenUsageTests.swift")
    (WORK / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Codenotch", platforms: [.macOS(.v15)], targets: [
    .target(name: "Codenotch", path: "Sources"),
    .testTarget(name: "CodenotchTests", dependencies: ["Codenotch"], path: "Tests")
], swiftLanguageModes: [.v5])
''')


def bundle_notices(resources):
    notices = resources / "Licenses"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "LICENSE", notices / "Codenotch-LICENSE.txt")
    shutil.copy2(ROOT / "ATTRIBUTION.md", notices / "ATTRIBUTION.md")
    shutil.copy2(ROOT / "Sources/Vendor/zstd/LICENSE", notices / "zstd-LICENSE.txt")
    for dependency in ("Sparkle", "swift-atomics", "swift-collections", "swift-nio", "swift-system"):
        checkout = WORK / ".build/checkouts" / dependency
        files = [p for p in checkout.iterdir() if p.is_file()
                 and p.name.upper().startswith(("LICENSE", "NOTICE", "COPYING"))]
        if not any(p.name.upper().startswith("LICENSE") for p in files):
            raise RuntimeError(f"Missing license for bundled dependency: {dependency}")
        target = notices / dependency
        target.mkdir(exist_ok=True)
        for source in files:
            shutil.copy2(source, target / source.name)


def package():
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "--build-system", "native", "--package-path", str(WORK), "--show-bin-path"], text=True).strip())
    app = ROOT / "build/Codenotch.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for name in ("MacOS", "Resources", "Frameworks"):
        (contents / name).mkdir(parents=True)
    shutil.copy2(binary_dir / "Codenotch", contents / "MacOS/Codenotch")
    for bundle in binary_dir.glob("*.bundle"):
        # A macOS resource bundle needs Contents/Resources. The flat SwiftPM
        # layout loads individual strings but reports no available languages.
        target = contents / "Resources" / bundle.name / "Contents"
        resources = target / "Resources"
        resources.mkdir(parents=True)
        for item in bundle.iterdir():
            if item.name == "Info.plist":
                continue
            if item.is_dir():
                shutil.copytree(item, resources / item.name)
            else:
                shutil.copy2(item, resources / item.name)
        metadata = {"CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "en",
                    "CFBundleIdentifier": "com.local." + bundle.stem.replace("_", "-")}
        if bundle.name == "Codenotch_Codenotch.bundle":
            metadata["CFBundleLocalizations"] = ["en", "zh-Hans", "fr", "de", "ja", "ru", "pt-BR"]
        (target / "Info.plist").write_bytes(plistlib.dumps(metadata))
    framework = next((WORK / ".build").rglob("Sparkle.framework"))
    shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
    run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(contents / "MacOS/Codenotch"))
    info = plistlib.loads((ROOT / "Sources/Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.local.codenotch", CFBundleExecutable="Codenotch",
                CFBundleShortVersionString="1.11.0-local", CFBundleVersion="13",
                CodenotchLocalBuild=True, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    iconset = ROOT / "build/Codenotch.iconset"
    iconset.mkdir(exist_ok=True)
    for icon in (ROOT / "Sources/Assets.xcassets/AppIcon.appiconset").glob("*.png"):
        shutil.copy2(icon, iconset / icon.name)
    run("iconutil", "-c", "icns", str(iconset), "-o", str(contents / "Resources/AppIcon.icns"))
    info["CFBundleIconFile"] = "AppIcon"
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    bundle_notices(contents / "Resources")
    run("codesign", "--force", "--deep", "--sign", "-", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    print(f"Built {app}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--tokens-only", action="store_true", help="Run token tests without app dependencies")
    parser.add_argument("--filter", help="Swift test name filter")
    args = parser.parse_args()
    # CLT 27 ships the State macro declaration without its SwiftUI plugin.
    # The installed macOS 26 SDK still offers the stable property wrapper.
    sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    if sdk.exists():
        os.environ["SDKROOT"] = str(sdk)
    if args.tokens_only:
        WORK = ROOT / "build/token-tests"
        args.test = True
        prepare_token_tests()
    else:
        prepare()
    command = ["swift", "test" if args.test else "build", "--build-system", "native", "--package-path", str(WORK), "--jobs", "4"]
    if "SDKROOT" in os.environ:
        command += ["--sdk", os.environ["SDKROOT"]]
    if args.tokens_only:
        frameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
        command += ["--disable-xctest", "--enable-swift-testing", "-Xswiftc", "-F" + frameworks,
                    "-Xlinker", "-F" + frameworks, "-Xlinker", "-rpath", "-Xlinker", frameworks]
    if args.filter:
        command += ["--filter", args.filter]
    run(*command)
    if not args.test:
        package()
