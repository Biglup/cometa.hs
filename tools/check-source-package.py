#!/usr/bin/env python3
"""Build and run a public-API consumer of a supplied Cabal source archive.

The project and extracted package live outside the checkout. Only the small
consumer sources are copied from it; no cabal.project.local, fixtures or build
outputs are reused. Cabal uses its configured package repository and store.
Use --offline only when all dependencies selected for this consumer are cached.
Supply the bundled native source archive, or explicit installed-library paths.
"""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def extract_package(archive, destination, description="cometa.cabal"):
    """Accept one ordinary sdist directory; reject links and escaping paths."""
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        roots = set()
        paths = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or not path.parts or ".." in path.parts
                    or "\\" in member.name or ":" in member.name
                    or not (member.isdir() or member.isfile())):
                raise ValueError(f"Unsafe archive member: {member.name!r}")
            if path in paths:
                raise ValueError(f"Duplicate archive member: {member.name!r}")
            paths.add(path)
            roots.add(path.parts[0])
        if len(roots) != 1:
            raise ValueError("Expected one source-package directory in archive")
        root = destination / roots.pop()
        if not any(path.parent == PurePosixPath(root.name) and path.name == description
                   for path in paths):
            raise ValueError(f"Archive root has no {description} package description")
        # Do not delegate link or path handling to tarfile.extractall, whose
        # default safety policy differs between supported Python versions.
        for member in members:
            target = destination / member.name
            target.resolve().relative_to(destination.resolve())
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as content, target.open("wb") as output:
                    shutil.copyfileobj(content, output)
        return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="cometa source .tar.gz produced by cabal sdist")
    parser.add_argument("--extra-include-dirs", type=Path, action="append", default=[],
                        help="existing native include directory (repeatable)")
    parser.add_argument("--extra-lib-dirs", type=Path, action="append", default=[],
                        help="existing native library directory (repeatable)")
    parser.add_argument("--native-archive", type=Path, help="bundled cardano-c-clib source archive")
    parser.add_argument("--test-package", action="store_true", help="also build and test the extracted binding")
    parser.add_argument("--offline", action="store_true",
                        help="disallow downloads; requires the consumer dependency plan to be cached")
    args = parser.parse_args()
    if args.native_archive:
        if args.extra_include_dirs or args.extra_lib_dirs:
            parser.error("Use a native source archive or installed-library paths, not both")
    elif not args.extra_include_dirs or not args.extra_lib_dirs:
        parser.error("Supply --native-archive or both native include and library paths")
    archive = args.archive.resolve(strict=True)
    includes = [path.resolve(strict=True) for path in args.extra_include_dirs]
    libraries = [path.resolve(strict=True) for path in args.extra_lib_dirs]
    if any(not path.is_dir() for path in includes + libraries):
        parser.error("Native include and library paths must be directories")

    with tempfile.TemporaryDirectory(prefix="cometa-source-consumer-") as directory:
        project = Path(directory)
        copied_archive = project / "source.tar.gz"
        shutil.copyfile(archive, copied_archive)
        package = extract_package(copied_archive, project / "source")
        consumer = project / "consumer"
        consumer.mkdir()
        for name in ("Main.hs", "package-consumer.cabal"):
            shutil.copyfile(ROOT / "test/package-consumer" / name, consumer / name)
        # Cabal supports quoted paths. JSON quoting preserves spaces and avoids
        # interpreting path text as additional project configuration.
        packages = [package, consumer]
        if args.native_archive:
            native = extract_package(args.native_archive.resolve(strict=True), project / "native", "cardano-c-clib.cabal")
            packages.append(native)
        configuration = [
            "packages: " + " ".join(json.dumps(path.as_posix(), ensure_ascii=False) for path in packages),
            "tests: " + ("True" if args.test_package else "False"),
            "benchmarks: False",
            "write-ghc-environment-files: never",
        ]
        if not args.native_archive:
            configuration.extend([
                "package cometa",
                "  flags: +system-cardano-c",
                "  extra-include-dirs: " + ", ".join(json.dumps(path.as_posix(), ensure_ascii=False) for path in includes),
                "  extra-lib-dirs: " + ", ".join(json.dumps(path.as_posix(), ensure_ascii=False) for path in libraries),
            ])
        (project / "cabal.project").write_text("\n".join(configuration) + "\n", encoding="utf-8")
        environment = os.environ.copy()
        # An ambient GHC package environment must not expose checkout packages.
        environment["GHC_ENVIRONMENT"] = "-"
        # Accommodate an explicitly supplied shared native library as well as
        # the pinned static CI build. No native files are built by this tool.
        runtime_variables = ("PATH",) if os.name == "nt" else ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH")
        for variable in runtime_variables:
            environment[variable] = os.pathsep.join(
                [str(path) for path in libraries] + ([environment[variable]] if environment.get(variable) else [])
            )
        target = "exe:package-consumer"
        options = ["--offline"] if args.offline else []
        commands = []
        if args.test_package:
            commands.extend([
                ["cabal", "build", "all", *options],
                ["cabal", "test", "all", "--test-show-details=direct", *options],
            ])
        commands.extend([
            ["cabal", "build", *options, target],
            ["cabal", "run", *options, target],
        ])
        for command in commands:
            subprocess.run(command, cwd=project, env=environment, check=True)
    print("Isolated source-package consumer verification passed")


if __name__ == "__main__":
    main()
