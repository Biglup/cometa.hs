#!/usr/bin/env python3
"""Generate the unpublished cardano-c-clib package from a clean pinned checkout.

Only tracked native sources and notices enter the package. Neither generation
nor the resulting Simple Cabal package invokes CMake or downloads dependencies.
"""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def git(source, *arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments])


def validate_source(source):
    pin = (ROOT / "native/cardano-c.ref").read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", pin):
        raise ValueError("native/cardano-c.ref must contain one full commit hash")
    if git(source, "rev-parse", "HEAD").decode().strip() != pin:
        raise ValueError(f"Native checkout HEAD must match native/cardano-c.ref ({pin})")
    if git(source, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Native checkout has tracked changes; use a clean pinned checkout")
    return pin, git(source, "ls-files", "-z").decode().split("\0")[:-1]


def field(name, values):
    return f"  {name}:\n" + "".join(f"    {value}\n" for value in values)


def matching(root, patterns):
    paths = set()
    for pattern in patterns:
        selected = {p.relative_to(root).as_posix() for p in root.glob(pattern) if p.is_file()}
        if not selected:
            raise ValueError(f"Manifest source pattern matches nothing: {pattern}")
        paths.update(selected)
    return sorted(paths)


def generate(source, destination, pin, tracked):
    manifest = json.loads((ROOT / "native/package.json").read_text())
    for name in tracked:
        path = Path(name)
        if len(path.parts) < 3 or path.parts[0] != "lib" or path.parts[1] not in manifest["source_roots"]:
            continue
        if path.suffix not in manifest["source_extensions"] and not path.name.upper().startswith(tuple(manifest["notice_prefixes"])):
            continue
        if path.parts[1] == "external" and any(part in {"test", "tests", "bench", "benchmarks", "scripts"} for part in path.parts[2:-1]):
            continue
        original = source / path
        if original.is_symlink():
            raise ValueError(f"Native payload contains a symlink: {path}")
        target = destination / "vendor" / path.relative_to("lib")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
    for original, target in [(source / "COPYING", "LICENSE"), (source / "VERSION", "VERSION"),
                             (ROOT / "native/NOTICE", "NOTICE")]:
        shutil.copyfile(original, destination / target)
    for original in sorted((ROOT / "native/licenses").iterdir()):
        target = destination / "licenses" / original.name
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(original, target)
    (destination / "NATIVE_REVISION").write_text(pin + "\n", encoding="utf-8")
    fields = dict(line.split("=", 1) for line in (source / "VERSION").read_text().splitlines() if "=" in line)
    version = ".".join(fields["VERSION_" + part] for part in ("MAJOR", "MINOR", "PATCH"))
    if fields.get("VERSION_PRERELEASE"):
        version += "-" + fields["VERSION_PRERELEASE"]
    replacements = dict(manifest["config_defaults"], CARDANO_C_VERSION=version)
    replacements.update({"CARDANO_C_VERSION_" + part: fields["VERSION_" + part] for part in ("MAJOR", "MINOR", "PATCH")})
    config = (source / "lib/src/config.h.in").read_text()
    for key, value in replacements.items():
        config = config.replace("@" + key + "@", value)
    if re.search(r"@[A-Za-z_][A-Za-z_0-9]*@", config):
        raise ValueError("Unresolved config.h template variable")
    (destination / "vendor/src/config.h").write_text(config, encoding="utf-8")
    (destination / "README.md").write_text(f"""# cardano-c-clib

Unpublished native source companion to the Cometa Haskell binding. Package
version {manifest['version']} bundles cardano-c {version}, revision `{pin}`.

This is a generated Cabal `build-type: Simple` package. Cabal compiles bundled
C sources using its selected C toolchain and optimization settings. Consumers
need no separately installed cardano-c library, CMake, Git or network download
for the native build. Six private libraries isolate bundled dependencies;
public cardano-c headers are installed by the main library for downstream FFI.

The configuration uses upstream defaults (collection growth 1.5, JSON depth
256), portable C blst, and upstream secp256k1 verification defines. Unix builds
link math and pthread and enable libsodium's initialization mutex. Compiler and
architecture selection remain the consumer toolchain's responsibility.

Sources and original notices are in `vendor/`; the payload excludes native test
suites, development scripts and build outputs. `NOTICE` and `licenses/` describe
the mixed licensing, including mini-gmp's LGPL/GPL alternatives. The complete
source is provided for consumers to rebuild and satisfy applicable license terms.

Regenerate from the Cometa repository with
`python3 tools/package-native.py /path/to/pinned/cardano-c`.
The generator verifies the committed native pin and a clean tracked checkout;
`--check` compares the generated package byte for byte without modifying it.
""", encoding="utf-8")
    license_files = ["LICENSE", "NOTICE", *matching(destination, ["licenses/*"]), *matching(destination, ["vendor/external/**/LICENSE", "vendor/external/**/COPYING"])]
    parts = [f"""cabal-version: 3.0
name: {manifest['name']}
version: {manifest['version']}
synopsis: Bundled cardano-c native sources for Cometa
description:
  Compiles pinned cardano-c and its six bundled C dependencies with Cabal.
  Installs the public native headers for Haskell FFI consumers. No CMake,
  Git checkout or installed cardano-c is required when building this package.
license: Apache-2.0 AND ISC AND BSD-2-Clause AND CC0-1.0 AND MIT AND (LGPL-3.0-or-later OR GPL-2.0-or-later) AND LicenseRef-RIPEMD160-Public-Domain
author: Biglup Labs and bundled dependency authors
maintainer: angel.castillob@protonmail.com
category: Blockchain
homepage: https://github.com/Biglup/cometa.hs
bug-reports: https://github.com/Biglup/cometa.hs/issues
build-type: Simple
"""]
    parts.append("license-files:\n" + "".join(f"  {path}\n" for path in license_files))
    parts.append("extra-source-files:\n" + "".join(f"  {p}\n" for p in matching(destination, ["**/*"])))
    options = manifest["cc_options"]
    translation_units = 0
    for name, library in manifest["libraries"].items():
        sources = matching(destination, library["sources"])
        translation_units += len(sources)
        parts.append(f"\nlibrary {name}\n  visibility: private\n  default-language: Haskell2010\n")
        parts.append(field("c-sources", sources))
        parts.append(field("include-dirs", manifest["include_dirs"]))
        parts.append("  cc-options: " + " ".join(options + ["-w"] + library["cc_options"]) + "\n")
        if name == "sodium":
            parts.append("  if !os(windows)\n    cc-options: -DHAVE_PTHREAD=1\n    extra-libraries: pthread\n")
    sources = matching(destination, ["vendor/src/**/*.c"])
    translation_units += len(sources)
    parts.append("\nlibrary\n  default-language: Haskell2010\n")
    parts.append("  build-depends: " + ", ".join(manifest["libraries"]) + "\n")
    parts.append(field("c-sources", sources))
    parts.append(field("include-dirs", manifest["include_dirs"]))
    parts.append(field("install-includes", [p.removeprefix("vendor/include/") for p in matching(destination, ["vendor/include/**/*.h"])]))
    parts.append("  cc-options: " + " ".join(options) + "\n")
    parts.append("  if !os(windows)\n    extra-libraries: m, pthread\n")
    (destination / (manifest["name"] + ".cabal")).write_text("".join(parts), encoding="utf-8")
    return translation_units


def contents(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="clean cardano-c checkout at native/cardano-c.ref")
    parser.add_argument("--output", type=Path, default=ROOT / ".native/cardano-c-clib", help="generated package directory")
    parser.add_argument("--check", action="store_true", help="compare output with regeneration without writing it")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    try:
        pin, tracked = validate_source(source)
        # Never replace the source checkout or any parent containing it.
        if output == source or output in source.parents or output == ROOT or output in ROOT.parents:
            raise ValueError("Output must not contain the source or Cometa checkout")
        with tempfile.TemporaryDirectory(prefix="cometa-native-package-") as directory:
            generated = Path(directory)
            count = generate(source, generated, pin, tracked)
            expected = contents(generated)
            if args.check:
                actual = contents(output) if output.is_dir() else {}
                differences = sorted(key for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key))
                if differences:
                    raise ValueError("Generated package differs: " + ", ".join(differences[:20]))
                print(f"Native package check passed ({len(expected)} files, {count} translation units)")
            else:
                if output.exists():
                    if not (output / "cardano-c-clib.cabal").is_file() or not (output / "NATIVE_REVISION").is_file():
                        raise ValueError("Refusing to replace a directory without generated-package markers")
                    shutil.rmtree(output)
                output.mkdir(parents=True)
                for name in expected:
                    target = output / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(generated / name, target)
                print(f"Generated {output} ({len(expected)} files, {count} translation units)")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"package-native: {error}\n")


if __name__ == "__main__":
    main()
