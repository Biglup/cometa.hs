#!/usr/bin/env python3
"""Build cardano-c's static target for the active GHC toolchain.

Usage: python3 tools/build-native.py SOURCE BUILD [--configure-cabal]
--configure-cabal overwrites cabal.project.local with this native path and -Werror.
Requires CMake and Ninja. CI checks out native/cardano-c.ref into SOURCE first.
"""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("build", type=Path)
    parser.add_argument("--configure-cabal", action="store_true")
    args = parser.parse_args()
    source, build = args.source.resolve(), args.build.resolve()
    pin = (Path(__file__).resolve().parents[1] / "native/cardano-c.ref").read_text().strip()
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != pin:
        parser.error(f"native checkout is {revision}; expected {pin}")
    configure = ["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
                 "-DBUILD_STATIC_LIBS=ON", "-DBUILD_SHARED_LIBS=ON",
                 "-DCARDANO_DISABLE_IPO=ON", "-DCLANG_TIDY_EXE=",
                 "-DCMAKE_BUILD_TYPE=RelWithDebInfo", "-DTESTING_ENABLED=OFF",
                 "-DEXAMPLES_ENABLED=OFF", "-DBENCHMARKS_ENABLED=OFF"]
    if os.name == "nt":
        # GHC 9.6 ships a MinGW-targeting LLVM toolchain. System clang can target
        # MSVC instead, producing incompatible objects or runtime dependencies.
        libdir = Path(subprocess.check_output(["ghc", "--print-libdir"], text=True).strip())
        compiler = libdir.parent / "mingw/bin/clang.exe"
        if not compiler.is_file():
            parser.error(f"GHC's MinGW clang is unavailable: {compiler}")
        configure.append(f"-DCMAKE_C_COMPILER={compiler.as_posix()}")
    subprocess.run(configure, check=True)
    subprocess.run(["cmake", "--build", str(build), "--target", "cardano-c-static",
                    "--parallel", "2"], check=True)
    include_dir = source / "lib/include"
    library_dir = build / "build/release/lib"
    if not (library_dir / "libcardano-c.a").is_file():
        parser.error(f"static archive not found in {library_dir}")
    # Forward slashes keep Cabal's quoted paths portable on Windows.
    if args.configure_cabal:
        Path("cabal.project.local").write_text(
            'package cometa\n'
            '  flags: +system-cardano-c\n'
            f'  extra-include-dirs: "{include_dir.as_posix()}"\n'
            f'  extra-lib-dirs: "{library_dir.as_posix()}"\n'
            '  ghc-options: -Werror\n')
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"include-dir={include_dir.as_posix()}\nlibrary-dir={library_dir.as_posix()}\n")


if __name__ == "__main__":
    main()
