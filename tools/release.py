#!/usr/bin/env python3
"""Check release evidence, seal built archives, and upload them to Hackage.

This tool never builds packages, creates tags, or changes source archives.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]


class ReleaseError(Exception):
    """An unmet release requirement, safe to show in workflow logs."""


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def cabal_field(text, field):
    matches = re.findall(rf"^{re.escape(field)}:\s*(\S+)\s*$", text, re.MULTILINE | re.IGNORECASE)
    require(len(matches) == 1, f"Expected one Cabal {field} field")
    return matches[0]


def package_metadata():
    cometa = (ROOT / "cometa.cabal").read_text(encoding="utf-8")
    native = json.loads((ROOT / "native/package.json").read_text(encoding="utf-8"))
    require(cabal_field(cometa, "name") == "cometa", "Unexpected main package name")
    version = cabal_field(cometa, "version")
    require(native.get("name") == "cardano-c-clib", "Unexpected native package name")
    for value in (version, native.get("version", "")):
        require(re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value), "Invalid package version")
    pin = (ROOT / "native/cardano-c.ref").read_text(encoding="utf-8").strip()
    require(re.fullmatch(r"[0-9a-f]{40}", pin), "Invalid native revision")
    return {"cometa": version, "cardano-c-clib": native["version"]}, pin


def source_revision(env):
    try:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                  check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        raise ReleaseError("Cannot determine checked-out source revision") from None
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "Invalid checked-out source revision")
    require(env.get("GITHUB_SHA") == revision, "Checkout must match GITHUB_SHA exactly")
    return revision


def check_mode(mode, versions, env):
    require(mode in {"candidate", "publish"}, "Invalid release mode")
    if mode == "publish":
        require(env.get("GITHUB_REF") == f"refs/tags/v{versions['cometa']}",
                "Publishing requires the existing tag refs/tags/v" + versions["cometa"])


def archive_contents(path, root):
    require(path.is_file() and not path.is_symlink(), f"Missing regular archive: {path.name}")
    result = {}
    try:
        with tarfile.open(path, "r:gz") as archive:
            for member in archive.getmembers():
                name = PurePosixPath(member.name)
                require(not name.is_absolute() and ".." not in name.parts
                        and name.parts and name.parts[0] == root
                        and (member.isfile() or member.isdir()),
                        f"Unsafe or unexpected archive entry in {path.name}")
                normalized = str(name)
                require(normalized not in result, f"Duplicate archive entry in {path.name}")
                result[normalized] = archive.extractfile(member).read() if member.isfile() else None
    except (tarfile.TarError, OSError):
        raise ReleaseError(f"Cannot read archive: {path.name}") from None
    return result


def validate_archives(directory, versions, pin):
    files = []
    for name in ("cardano-c-clib", "cometa"):
        stem = f"{name}-{versions[name]}"
        filename = f"{stem}.tar.gz"
        contents = archive_contents(directory / filename, stem)
        cabal = contents.get(f"{stem}/{name}.cabal")
        require(isinstance(cabal, bytes), f"Missing package description in {filename}")
        cabal = cabal.decode("utf-8")
        require(cabal_field(cabal, "name") == name and cabal_field(cabal, "version") == versions[name],
                f"Incorrect package name/version in {filename}")
        if name == "cardano-c-clib":
            require(contents.get(f"{stem}/NATIVE_REVISION") == (pin + "\n").encode(),
                    "Generated native archive does not match native source pin")
        else:
            require(contents.get(f"{stem}/native/cardano-c.ref", b"").strip() == pin.encode(),
                    "Cometa archive does not match native source pin")
            dependencies = re.findall(r"\bcardano-c-clib\s*([^,\n]*)", cabal)
            require(dependencies and all(re.fullmatch(r"==\s*" + re.escape(versions["cardano-c-clib"]) + r"\s*", value)
                                         for value in dependencies),
                    "Cometa must depend on the exact native package version")
        files.append(filename)
    docs_root = f"cometa-{versions['cometa']}-docs"
    docs_name = docs_root + ".tar.gz"
    docs = archive_contents(directory / docs_name, docs_root)
    require(isinstance(docs.get(docs_root + "/index.html"), bytes), "Documentation archive lacks index.html")
    files.append(docs_name)
    return files


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checksum_text(directory, names):
    return "".join(f"{sha256(directory / name)}  {name}\n" for name in sorted(names))


def prepare(directory, mode, env):
    versions, pin = package_metadata()
    check_mode(mode, versions, env)
    revision = source_revision(env)
    names = validate_archives(directory, versions, pin)
    manifest = {"schema_version": 1, "mode": mode, "source_revision": revision,
                "native_revision": pin, "packages": versions,
                "files": {name: {"sha256": sha256(directory / name)} for name in names}}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (directory / "SHA256SUMS").write_text(checksum_text(directory, names + ["manifest.json"]), encoding="utf-8")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"version={versions['cometa']}\n")
    print(f"Prepared cometa {versions['cometa']} ({mode}), revision {revision}")
    return manifest


def validate_manifest(directory, mode, env):
    versions, pin = package_metadata()
    check_mode(mode, versions, env)
    revision = source_revision(env)
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    require(manifest.get("schema_version") == 1 and manifest.get("mode") == mode
            and manifest.get("packages") == versions and manifest.get("native_revision") == pin
            and manifest.get("source_revision") == revision, "Manifest does not match release checkout or mode")
    names = validate_archives(directory, versions, pin)
    require(manifest.get("files") == {name: {"sha256": sha256(directory / name)} for name in names},
            "Artifact hashes do not match manifest")
    require((directory / "SHA256SUMS").read_text(encoding="utf-8")
            == checksum_text(directory, names + ["manifest.json"]), "SHA256SUMS does not match release artifacts")
    return manifest


def published_hash(name, version):
    """Only 404 means absent. Other failures must prevent an upload."""
    stem = f"{name}-{version}"
    url = f"https://hackage.haskell.org/package/{stem}/{stem}.tar.gz"
    try:
        with urlopen(url, timeout=60) as response:
            require(response.status == 200, "Unexpected Hackage package response")
            digest = hashlib.sha256()
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
            return digest.hexdigest()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise ReleaseError(f"Hackage lookup failed for {stem} (HTTP {error.code})") from None
    except (OSError, URLError):
        raise ReleaseError(f"Hackage lookup failed for {stem}") from None


def upload_diagnostics(error, token):
    """Keep server errors useful without exposing the upload credential."""
    text = "\n".join(value for value in (error.stdout, error.stderr) if value)
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    forms = {token, repr(token)[1:-1], json.dumps(token)[1:-1], quote(token, safe="")}
    for value in sorted(forms, key=len, reverse=True):
        if value:
            text = text.replace(value, "[REDACTED]")
    # Remove terminal control sequences and flatten output so remote diagnostics
    # cannot introduce GitHub workflow commands on a new line.
    text = " | ".join(text.splitlines())
    text = "".join(char for char in text if char.isprintable())
    if token:
        text = text.replace(token, "[REDACTED]")
    return text[:4000] or "No diagnostic output was returned"


def cabal_upload(path, mode, token, documentation=False):
    command = ["cabal", "upload", "--token=" + token]
    if mode == "publish":
        command.append("--publish")
    if documentation:
        command.append("--documentation")
    command.append(str(path))
    # Never render the exception or command: both can contain the upload token.
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        diagnostic = upload_diagnostics(error, token)
        raise ReleaseError(f"Cabal upload failed for {path.name} (exit {error.returncode}): {diagnostic}") from None
    except OSError:
        raise ReleaseError(f"Cannot start Cabal upload for {path.name}") from None


def upload(directory, mode, env):
    manifest = validate_manifest(directory, mode, env)
    token = env.get("HACKAGE_TOKEN", "")
    require(bool(token.strip()), "HACKAGE_TOKEN is required")
    # Preflight both immutable source versions before any mutation, so a later
    # mismatch cannot cause a partial upload of the native package.
    pending = []
    for name in ("cardano-c-clib", "cometa"):
        version = manifest["packages"][name]
        filename = f"{name}-{version}.tar.gz"
        existing = published_hash(name, version)
        if existing is not None:
            require(not (mode == "candidate" and name == "cometa"),
                    "Cometa version is already published; use a new version for a candidate")
            require(existing == manifest["files"][filename]["sha256"],
                    f"Published {name}-{version} differs from this archive; refusing replacement")
            print(f"Skipping identical published source package {name}-{version}")
        else:
            pending.append(filename)
    for filename in pending:
        cabal_upload(directory / filename, mode, token)
        print(f"Uploaded {filename} ({mode})")
    filename = f"cometa-{manifest['packages']['cometa']}-docs.tar.gz"
    cabal_upload(directory / filename, mode, token, documentation=True)
    print(f"Uploaded {filename} ({mode})")


def main(argv=None, env=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "upload"):
        command = commands.add_parser(name)
        command.add_argument("--directory", type=Path, default=Path("release-artifacts"))
        command.add_argument("--mode", choices=("candidate", "publish"), required=True)
    args = parser.parse_args(argv)
    env = os.environ if env is None else env
    try:
        if args.command == "prepare":
            prepare(args.directory, args.mode, env)
        else:
            upload(args.directory, args.mode, env)
    except (ReleaseError, OSError, ValueError, KeyError, TypeError) as error:
        # These errors do not include upload command diagnostics, but still redact
        # a supplied token defensively before displaying any message.
        message = str(error)
        if env.get("HACKAGE_TOKEN"):
            message = message.replace(env["HACKAGE_TOKEN"], "[REDACTED]")
        print("Release refused: " + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
