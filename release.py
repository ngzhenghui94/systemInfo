#!/usr/bin/env python3
"""Build, Developer ID sign, notarize, staple and publish an immutable update."""
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
APP = "systemInfo"
SLUG = "systeminfo"
IDENTIFIER = "danielninetyfour.systemInfo"
TEAM = "F57QJC4XU3"
REPO = "ngzhenghui94/homebrew-tap"
REMOTE = f"https://github.com/{REPO}.git"
CHECKOUT = ROOT / ".release/update-tap"
DERIVED = ROOT / ".release/DerivedData"
ACCOUNT = "local.swissKnife"
PUBLIC_KEY = "ogSJSN3POPY/0djBMOpOVyHZxcLbooaAfJYwnin6RCw="
REQUIREMENT = (f'=identifier "{IDENTIFIER}" and anchor apple generic and '
               'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
               'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
               f'certificate leaf[subject.OU] = "{TEAM}"')
MACHO = {bytes.fromhex(v) for v in ("feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def run(label, *command):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        log = ROOT / ".release" / "failure.log"
        log.parent.mkdir(exist_ok=True)
        # Only local diagnostics are retained; signing/keychain output is never disclosed.
        if command[0] == "xcodebuild":
            log.write_text(result.stdout + result.stderr)
        raise RuntimeError(f"{label} failed (exit {result.returncode}); inspect local Xcode diagnostics if present")
    return result.stdout


def git(*args):
    return run("Release checkout", "git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "-C", CHECKOUT, *args)


def version_parts(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Release version must be numeric, with at most three components")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def next_version(versions, builds):
    version = max(versions, key=version_parts).split(".")
    version[-1] = str(int(version[-1]) + 1)
    if any(not re.fullmatch(r"[1-9]\d{0,3}", str(b)) for b in builds):
        raise ValueError("Expected positive integer build numbers below 10000")
    build = max(map(int, builds)) + 1
    if build > 9999:
        raise ValueError("Build numbering exhausted")
    return ".".join(version), str(build)


def selftest():
    assert next_version(["1.9", "1.10"], ["1", "9"]) == ("1.11", "10")
    assert next_version(["1.1", "2.0.4"], ["3", "4"]) == ("2.0.5", "5")
    for value in ("../1", "1..2", "", "1.2-beta", "1.2.3.4"):
        try:
            version_parts(value)
        except ValueError:
            continue
        raise AssertionError("Unsafe version accepted")
    for value in ("0", "-1", "10000", "9999"):
        try:
            next_version(["1.0"], [value])
        except ValueError:
            continue
        raise AssertionError("Invalid build accepted")
    print("PASS: release numbering and unsafe input checks", flush=True)


def info(app):
    value = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if value.get("CFBundleIdentifier") != IDENTIFIER:
        raise RuntimeError(f"Refusing unrelated app at {app}")
    return value


def verify_entitlements(app):
    for name, bundle in (("SystemInfo", app), ("Widget", app / "Contents/PlugIns/SystemInfoWidgetExtension.appex")):
        expected = plistlib.loads((ROOT / f"{name}-Release.entitlements").read_bytes())
        actual = plistlib.loads(run("Read declared release entitlements", "codesign", "-d", "--entitlements", ":-", bundle).encode())
        if any(actual.get(key) != value for key, value in expected.items()):
            raise RuntimeError(f"{name} capability entitlement lost")
        if actual.get("com.apple.security.get-task-allow"):
            raise RuntimeError(f"{name} has a development-only entitlement")


def main():
    ROOT.joinpath(".release").mkdir(exist_ok=True)
    run("Existing update key without prompts", "/usr/bin/swift", ROOT / "signing.swift", "check", ACCOUNT, PUBLIC_KEY)
    identity_text = run("Developer ID identity", "security", "find-identity", "-v", "-p", "codesigning")
    matches = re.findall(r'\b([0-9A-Fa-f]{40})\s+"Developer ID Application: [^"\n]+ \(' + TEAM + r'\)"', identity_text)
    if len(matches) != 1:
        raise RuntimeError("Exactly one Developer ID Application certificate for F57QJC4XU3 is required")
    identity = matches[0]
    access = json.loads(run("Release destination", "gh", "api", f"repos/{REPO}"))
    if access.get("private") or access.get("default_branch") != "main" or not access.get("permissions", {}).get("push"):
        raise RuntimeError("Expected push access to the existing public artifact repository main")
    if not CHECKOUT.exists():
        run("Clone private release slice", "git", "clone", "--branch", "main", REMOTE, CHECKOUT)
    if git("remote", "get-url", "origin").strip() != REMOTE or git("branch", "--show-current").strip() != "main":
        raise RuntimeError("Unexpected release slice remote or branch")
    if git("status", "--porcelain", "--untracked-files=all").strip() or git("rev-list", "--count", "origin/main..HEAD").strip() != "0":
        raise RuntimeError("Preserve and resolve unfinished release slice before another build")
    git("fetch", "origin", "main")
    git("merge", "--ff-only", "origin/main")
    feed = CHECKOUT / f"appcasts/{SLUG}.xml"
    versions, builds = ["1.0"], ["1"]
    # Resolve the pinned official tools from this project's own Xcode package artifacts.
    run("Resolve Sparkle", "xcodebuild", "-resolvePackageDependencies", "-project", f"{APP}.xcodeproj", "-scheme", APP, "-clonedSourcePackagesDirPath", ROOT / ".release/SourcePackages")
    tools = list((ROOT / ".release/SourcePackages/artifacts").glob("**/bin/sign_update"))
    if len(tools) != 1:
        raise RuntimeError("Expected one official Sparkle 2.10.0 signing tool")
    signer = tools[0]
    if feed.exists():
        run("Existing feed signature", "/usr/bin/swift", ROOT / "signing.swift", "verify", PUBLIC_KEY, feed)
        xml = ET.parse(feed)
        ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        versions += [v.text for v in xml.findall(".//s:shortVersionString", ns)]
        builds += [v.text for v in xml.findall(".//s:version", ns)]
    pages = json.loads(run("Existing immutable tags", "gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    for page in pages:
        versions += [r["tag_name"].removeprefix(f"{SLUG}-v") for r in page if r["tag_name"].startswith(f"{SLUG}-v")]
    releases = ROOT / "build/releases"
    for directory in releases.iterdir() if releases.exists() else []:
        if directory.is_dir():
            versions.append(directory.name)
            record = json.loads((directory / "release.json").read_text())
            builds.append(record["build"])
    version, build = next_version(versions, builds)
    output = releases / version
    output.mkdir(parents=True, exist_ok=False)
    (output / "release.json").write_text(json.dumps({"version": version, "build": build, "status": "Building"}, indent=2) + "\n")
    print(f"Building {APP} {version} ({build}); preserving previous releases", flush=True)
    run("Signed Xcode Release build", "xcodebuild", "-quiet", "-project", f"{APP}.xcodeproj", "-scheme", APP, "-configuration", "Release", "-sdk", "macosx", "-destination", "generic/platform=macOS", "-derivedDataPath", DERIVED, "-clonedSourcePackagesDirPath", ROOT / ".release/SourcePackages", f"MARKETING_VERSION={version}", f"CURRENT_PROJECT_VERSION={build}", "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={identity}", f"DEVELOPMENT_TEAM={TEAM}", "ENABLE_HARDENED_RUNTIME=YES", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "OTHER_CODE_SIGN_FLAGS=--timestamp", "build")
    source = DERIVED / f"Build/Products/Release/{APP}.app"
    if info(source).get("CFBundleVersion") != build:
        raise RuntimeError("Xcode did not apply release numbering")
    app = output / f"{APP}.app"
    run("Copy release app", "ditto", source, app)
    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    if not sparkle.exists():
        raise RuntimeError("Sparkle framework was not embedded")
    notices = app / "Contents/Resources/Sparkle-LICENSE.txt"
    notices.parent.mkdir(parents=True, exist_ok=True)
    licenses = list(signer.parent.parent.glob("LICENSE"))
    if len(licenses) != 1:
        raise RuntimeError("Missing Sparkle distribution license")
    shutil.copy2(licenses[0], notices)
    binaries = []
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    binaries.append(path)
    bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in (".framework", ".xpc", ".app", ".appex", ".systemextension")]
    for path in sorted(binaries + bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
        run("Preserve entitlements and sign", "codesign", "--force", "--timestamp", "--options", "runtime", "--preserve-metadata=entitlements", "--sign", identity, path)
    run("Verify nested signatures", "codesign", "--verify", "--deep", "--strict", app)
    run("Verify stable app identity", "codesign", "--verify", "-R", REQUIREMENT, app)
    verify_entitlements(app)
    test = ROOT / ".release/update-safety-test"
    run("Compile update safety checks", "xcrun", "swiftc", "-parse-as-library", "-F", signer.parent.parent / "Sparkle.xcframework/macos-arm64_x86_64", "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", sparkle.parent, ROOT / "systemInfo/Updates.swift", ROOT / "Tests/UpdatesTests.swift", "-o", test)
    print(run("Native update safety checks", test), end="", flush=True)
    archive = output / "notarization.zip"
    run("Notarization archive", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    record = output / "notarization.json"
    record.write_text(json.dumps({"version": version, "status": "Submitting"}) + "\n")
    result = subprocess.run(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", "notary", "--wait", "--output-format", "json"], capture_output=True, text=True)
    try:
        response = json.loads(result.stdout)
    except ValueError:
        raise RuntimeError("Unknown Apple submission outcome; inspect notarytool history before retrying") from None
    identifier, status = response.get("id"), response.get("status")
    if not isinstance(identifier, str) or not re.fullmatch(r"[a-fA-F0-9-]{36}", identifier):
        raise RuntimeError("Missing Apple submission ID; inspect submission history before retrying")
    record.write_text(json.dumps({"version": version, "id": identifier, "status": status}, indent=2) + "\n")
    print(f"Apple submission {identifier}: {status}", flush=True)
    if result.returncode or status != "Accepted":
        raise RuntimeError("Notarization not accepted; no publication performed")
    run("Staple", "xcrun", "stapler", "staple", app)
    run("Validate ticket", "xcrun", "stapler", "validate", app)
    run("Verify stapled code", "codesign", "--verify", "--deep", "--strict", "-R", REQUIREMENT, app)
    run("Gatekeeper", "spctl", "--assess", "--type", "execute", app)
    package = output / f"{APP}-{version}.zip"
    run("Signed update archive", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, package)
    signature = run("EdDSA archive signature without prompts", "/usr/bin/swift", ROOT / "signing.swift", "sign", signer, ACCOUNT, PUBLIC_KEY, package).strip()
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        raise RuntimeError("Invalid archive signature")
    run("Verify archive EdDSA", "/usr/bin/swift", ROOT / "signing.swift", "verify", PUBLIC_KEY, package, signature)
    tag = f"{SLUG}-v{version}"
    url = f"https://github.com/{REPO}/releases/download/{tag}/{package.name}"
    appcast = output / "appcast.xml"
    appcast.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>{APP} Updates</title><link>https://github.com/{REPO}</link><description>Signed and notarized {APP} updates</description>
<item><title>{APP} {version}</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>{info(app)["LSMinimumSystemVersion"]}</sparkle:minimumSystemVersion>
<enclosure url="{url}" length="{package.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item>
</channel></rss>
''')
    run("Sign appcast without prompts", "/usr/bin/swift", ROOT / "signing.swift", "sign", signer, ACCOUNT, PUBLIC_KEY, appcast)
    run("Verify signed appcast", "/usr/bin/swift", ROOT / "signing.swift", "verify", PUBLIC_KEY, appcast)
    assets = [package, appcast]
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in assets}
    run("Create immutable draft", "gh", "release", "create", tag, "--repo", REPO, "--target", "main", "--draft", "--title", f"{APP} {version}", "--notes", "Developer ID signed, Apple notarized and stapled. Signed Sparkle archive and appcast. Authored app source is not included.", *assets)
    with tempfile.TemporaryDirectory(prefix=f"{SLUG}-download-") as temporary:
        run("Download uploaded draft", "gh", "release", "download", tag, "--repo", REPO, "--dir", temporary)
        for name, digest in hashes.items():
            if hashlib.sha256((Path(temporary) / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError("Draft asset checksum mismatch; feed unchanged")
        run("Publish verified assets", "gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest=false")
        for name, digest in hashes.items():
            downloaded = Path(temporary) / name
            run("Verify public HTTPS asset", "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--output", downloaded, f"https://github.com/{REPO}/releases/download/{tag}/{name}")
            if hashlib.sha256(downloaded.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Public checksum mismatch; feed unchanged")
    cask = CHECKOUT / f"Casks/{SLUG}.rb"
    cask.parent.mkdir(exist_ok=True)
    cask.write_text(f'''cask "{SLUG}" do
  version "{version}"
  sha256 "{hashes[package.name]}"
  url "{url}"
  name "{APP}"
  desc "Live system information and monitoring"
  homepage "https://github.com/{REPO}"
  depends_on macos: ">= {info(app)["LSMinimumSystemVersion"]}"
  app "{APP}.app"
end
''')
    feed.parent.mkdir(exist_ok=True)
    shutil.copy2(appcast, feed)
    git("add", "--", f"Casks/{SLUG}.rb", f"appcasts/{SLUG}.xml")
    git("commit", "-m", f"Publish notarized {APP} {version} and signed feed")
    git("fetch", "origin", "main")
    git("rebase", "origin/main")
    git("push", "origin", "HEAD:main")
    final = ROOT / f"build/{APP}.app"
    if final.exists():
        info(final)
        if final.is_symlink():
            raise RuntimeError("Refusing final app symlink")
        shutil.rmtree(final)
    run("Promote published app", "ditto", app, final)
    print(f"PASS: signed, notarized, stapled, assessed; published https://github.com/{REPO}/releases/tag/{tag}", flush=True)
    print(f"Ready: {final}\nImmutable app: {app}\nArchive: {package}", flush=True)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--selftest"]:
            selftest()
        elif not sys.argv[1:]:
            selftest()
            main()
        else:
            raise ValueError("Usage: ./build.sh [--selftest]")
    except (OSError, RuntimeError, ValueError, KeyError, ET.ParseError) as error:
        sys.exit(f"BLOCKED: {error}. Preserve build/releases and .release/update-tap; inspect recorded submissions/drafts before retrying.")
