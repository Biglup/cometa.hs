#!/usr/bin/env python3
"""Build a portable Haddock archive containing both public library components."""

import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "_build" / "api"


def main():
    subprocess.run(
        ["cabal", "haddock", "lib:cometa", "lib:blockfrost",
         "--haddock-hyperlink-source",
         "--haddock-html-location=https://hackage.haskell.org/package/$pkg-$version/docs"],
        cwd=ROOT, check=True,
    )
    plan = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
    libraries = {entry["component-name"]: entry for entry in plan["install-plan"]
                 if entry.get("pkg-name") == "cometa"
                 and entry.get("component-name") in ("lib", "lib:blockfrost")}
    version = libraries["lib"]["pkg-version"]
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    for component, directory in (("lib", "core"), ("lib:blockfrost", "blockfrost")):
        source = Path(libraries[component]["dist-dir"]) / "doc/html/cometa"
        shutil.copytree(source, OUTPUT / directory)

    # Haddock treats the main library as an external dependency of the public
    # sublibrary. Keep third-party links on Hackage and link our core API locally.
    core_url = f"https://hackage.haskell.org/package/cometa-{version}/docs"
    for path in OUTPUT.rglob("*"):
        if path.suffix not in (".html", ".js", ".json"):
            continue
        content = path.read_text(encoding="utf-8")
        relative = os.path.relpath(OUTPUT / "core", path.parent).replace(os.sep, "/")
        path.write_text(content.replace(core_url, relative), encoding="utf-8")

    provider = OUTPUT / "blockfrost/Cometa-Provider-Blockfrost.html"
    if '../core/Cometa-Provider.html#t:Provider' not in provider.read_text(encoding="utf-8"):
        raise RuntimeError("Blockfrost documentation is missing its portable Provider link")
    (OUTPUT / "index.html").write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<title>Cometa.hs API reference</title><h1>Cometa.hs API reference</h1>'
        '<ul><li><a href="core/index.html">Core library</a></li>'
        '<li><a href="blockfrost/index.html">Blockfrost provider</a></li></ul></html>\n',
        encoding="utf-8",
    )
    print(f"Portable API documentation: {OUTPUT}")


if __name__ == "__main__":
    main()
