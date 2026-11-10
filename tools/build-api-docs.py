#!/usr/bin/env python3
"""Build portable API documentation or a Hackage documentation tarball."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "_build" / "api"


def prepare_links(output, version):
    # Keep package-local links portable, including links from rendered sources.
    for path in output.rglob("*"):
        if path.suffix not in (".html", ".js", ".json"):
            continue
        relative = os.path.relpath(output, path.parent).replace(os.sep, "/")
        content = path.read_text(encoding="utf-8")
        for prefix in ("https://hackage.haskell.org", ""):
            content = content.replace(
                f"{prefix}/package/cometa-{version}/docs", relative)
        path.write_text(content, encoding="utf-8")

    # Haddock emits instance-location links even when the defining internal
    # module is hidden. Keep that location text without a dead hyperlink.
    anchor = re.compile(r'<a\b[^>]*\bhref="([^"]+)"[^>]*>(.*?)</a>', re.DOTALL)
    for path in output.rglob("*.html"):
        def replace(match):
            url = urlsplit(match.group(1))
            target = path.parent / url.path
            if (not url.scheme and not url.netloc and not url.path.startswith("/")
                    and target.name.startswith("Cometa-")
                    and "-Internal-" in target.name and target.suffix == ".html"
                    and not target.exists()):
                return match.group(2)
            return match.group(0)
        path.write_text(anchor.sub(replace, path.read_text(encoding="utf-8")),
                        encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hackage", action="store_true",
                        help="create dist-newstyle/cometa-VERSION-docs.tar.gz for Hackage")
    args = parser.parse_args()
    flags = (["--haddock-for-hackage"] if args.hackage else
             ["--haddock-html-location=https://hackage.haskell.org/package/$pkg-$version/docs"])
    subprocess.run(
        ["cabal", "haddock", "lib:cometa", "--haddock-hyperlink-source", *flags],
        cwd=ROOT, check=True,
    )
    plan = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
    library = next(entry for entry in plan["install-plan"]
                   if entry.get("pkg-name") == "cometa"
                   and entry.get("component-name") == "lib")
    version = library["pkg-version"]
    name = f"cometa-{version}-docs"
    source = Path(library["dist-dir"]) / "doc/html" / (name if args.hackage else "cometa")
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    shutil.copytree(source, OUTPUT)
    if args.hackage:
        # Cabal delegates the Hackage contents page to the package page. Also
        # provide a local module index so the downloaded archive is browsable.
        subprocess.run(
            ["haddock", "--gen-contents", "--title=Cometa.hs API reference",
             f"--odir={OUTPUT}", f"--read-interface=.,{OUTPUT / 'cometa.haddock'}"],
            cwd=ROOT, check=True,
        )
    prepare_links(OUTPUT, version)
    index = (OUTPUT / "index.html").read_text(encoding="utf-8")
    for module in ("Cometa.html", "Cometa-Provider-Blockfrost.html"):
        if module not in index or not (OUTPUT / module).is_file():
            raise RuntimeError(f"API documentation is missing {module}")
    if not (OUTPUT / "cometa.haddock").is_file():
        raise RuntimeError("API documentation is missing its Haddock interface")

    if args.hackage:
        # Hackage expects portable tar entries within PACKAGE-VERSION-docs/.
        # Repack Cabal's output after removing the dead hidden-module anchors.
        archive = ROOT / "dist-newstyle" / f"{name}.tar.gz"
        temporary = archive.with_suffix(".tmp")
        with tarfile.open(temporary, "w:gz", format=tarfile.USTAR_FORMAT) as tar:
            tar.add(OUTPUT, arcname=name)
        temporary.replace(archive)
        print(f"Hackage API documentation: {archive}")
    else:
        print(f"Portable API documentation: {OUTPUT}")


if __name__ == "__main__":
    main()
