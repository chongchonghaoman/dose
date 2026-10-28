#!/usr/bin/env python3
"""Validate a public application and (optionally) its prepared GitHub release.

Uses Sparkle's own verifier. No downloading, installing, signing or publishing.
"""
import base64
import hashlib
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "fuyuan9972-svg.LightTable.updates"
NS = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def require(condition, message):
    if not condition:
        raise ValueError(message)
    print("PASS " + message)


def validate(app, feed=None):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    config = plistlib.loads((ROOT / "Configuration/Updates.plist").read_bytes())
    version = (ROOT / "VERSION").read_text().strip()
    require(info.get("CFBundleIdentifier") == "local.ourlighttable.desktop", "application identity")
    require(info.get("CFBundleVersion") == info.get("CFBundleShortVersionString") == version,
            "application version matches VERSION")
    guide_source = (ROOT / "Sources/LightTableApp/FeatureGuideState.swift").read_text()
    guide_version = re.search(r'static let releaseVersion = "([^"]+)"', guide_source)
    require(guide_version is not None and guide_version.group(1) == version,
            "release includes its own first-launch update guide")
    require(all(info.get(key) == value for key, value in config.items()), "public updater configuration")
    require(len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32, "Ed25519 public key")
    binary = app / "Contents/MacOS/LightTable"
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    require(arch == "arm64", "Apple Silicon release architecture")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("PASS application and embedded helper signatures")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    require((framework / "Sparkle").is_symlink() and (framework / "Versions/Current").is_symlink(),
            "Sparkle framework symlinks preserved")
    require((framework / "Versions/Current/Autoupdate").is_file() and
            (framework / "Versions/Current/Updater.app/Contents/MacOS/Updater").is_file(),
            "Sparkle installation and relaunch helpers embedded")
    libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    paths = [line.strip().split(" (", 1)[0] for line in libraries]
    require(any(path.startswith("@rpath/Sparkle.framework/") for path in paths), "relative Sparkle linkage")
    require(all(path.startswith(("@rpath/", "/System/Library/", "/usr/lib/")) for path in paths),
            "no external development library dependencies")
    rpaths = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    require("@executable_path/../Frameworks" in rpaths, "bundled framework runtime search path")
    for name in ("ShutterClick", "ShutterClickRoom", "ShutterArrivalRoom", "SlideChange", "ProjectorStart"):
        original = ROOT / f"Sources/LightTableApp/Resources/{name}.wav"
        bundled = app / f"Contents/Resources/{name}.wav"
        require(hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(bundled.read_bytes()).digest(),
                f"bundled {name} matches the selected sound")
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "Sparkle-LICENSE.txt"):
        require((app / "Contents/Resources" / name).is_file(), f"bundled {name}")
    scene_source = ROOT / "Sources/LightTableApp/Resources/ReturnToPast"
    scene_bundle = app / "Contents/Resources/ReturnToPast"
    resource_hashes = {str(path.relative_to(scene_source)): hashlib.sha256(path.read_bytes()).digest()
                       for path in scene_source.rglob("*") if path.is_file()}
    bundled_hashes = {str(path.relative_to(scene_bundle)): hashlib.sha256(path.read_bytes()).digest()
                      for path in scene_bundle.rglob("*") if path.is_file()}
    require(len(resource_hashes) >= 53 and resource_hashes == bundled_hashes,
            "Return to Past worker, viewer, SHARP source and licenses match production resources")
    require(all((scene_bundle / name).is_file() for name in (
        "viewer-licenses.txt", "sharp-source/LICENSE", "sharp-source/LICENSE_MODEL",
        "sharp-source/ACKNOWLEDGEMENTS", "sharp-source/PROVENANCE.txt")),
        "Return to Past third-party licenses and provenance included")
    if feed is None:
        return
    items = ET.parse(feed).findall("./channel/item")
    require(len(items) == 1, "release feed has one complete version")
    item = items[0]
    require(item.findtext("s:version", namespaces=NS) == version, "feed version matches application")
    require(item.findtext("s:minimumSystemVersion", namespaces=NS) == "14.0", "feed minimum macOS version")
    # Sparkle generates hardwareRequirements for arm64-only builds.
    hardware = item.findtext("s:hardwareRequirements", namespaces=NS)
    require(hardware == "arm64", "feed excludes unsupported Intel Macs")
    enclosure = item.find("enclosure")
    require(enclosure is not None, "feed includes downloadable archive")
    archive = feed.parent / f"LightTable-v{version}-macOS-arm64.zip"
    expected_url = f"https://github.com/fuyuan9972-svg/LightTable/releases/download/v{version}/{archive.name}"
    require(enclosure.get("url") == expected_url, "download URL uses the immutable release tag")
    require(int(enclosure.get("length", "0")) == archive.stat().st_size, "archive length matches feed")
    signature = enclosure.get("{" + NS["s"] + "}edSignature", "")
    require(len(base64.b64decode(signature, validate=True)) == 64, "archive includes Ed25519 signature")
    with zipfile.ZipFile(archive) as package:
        require(package.testzip() is None, "archive contents pass CRC verification")
        # macOS ditto writes UTF-8 names without always setting ZIP's UTF-8 flag.
        entries = {(entry.filename if entry.flag_bits & 0x800 else
                    entry.filename.encode("cp437").decode("utf-8")): entry
                   for entry in package.infolist()}
        packaged_info = plistlib.loads(package.read(entries["观片台.app/Contents/Info.plist"]))
        require(packaged_info == info, "archive contains the verified application")
        for name in ("ShutterClick", "ShutterClickRoom", "ShutterArrivalRoom", "SlideChange", "ProjectorStart"):
            require(package.read(entries[f"观片台.app/Contents/Resources/{name}.wav"]) ==
                    (app / f"Contents/Resources/{name}.wav").read_bytes(), f"archive contains {name}")
        require(all(hashlib.sha256(package.read(entries[f"观片台.app/Contents/Resources/ReturnToPast/{name}"])).digest() == digest
                    for name, digest in resource_hashes.items()),
                "archive contains all verified Return to Past resources")
    verifier = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    subprocess.run([str(verifier), "--account", ACCOUNT, "--verify", str(archive), signature], check=True)
    subprocess.run([str(verifier), "--account", ACCOUNT, "--verify", str(feed)], check=True)
    print("PASS archive and feed signatures verified by Sparkle")


if __name__ == "__main__":
    try:
        if len(sys.argv) not in (2, 3):
            raise ValueError("Usage: check-update-bundle.py app-path [appcast.xml]")
        validate(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"FAIL {error}")
