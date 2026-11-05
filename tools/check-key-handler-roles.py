#!/usr/bin/env python3
"""Check public handler capability boundaries as an external package consumer."""
import pathlib
import subprocess
import tempfile

PRELUDE = """module Boundary where
import Cometa.KeyHandler.Software
import Data.Coerce (coerce)
"""
CASES = {
    "Valid": (True, "valid :: Handler Bip32 -> Handler Bip32\nvalid = id\n"),
    "Coerce": (False, "invalid :: Handler Bip32 -> Handler Ed25519\ninvalid = coerce\n"),
    "WrongCapability": (False, "invalid key = publicKey (key :: Handler Bip32)\n"),
}
with tempfile.TemporaryDirectory(prefix="cometa-handler-roles-") as directory:
    for name, (should_compile, body) in CASES.items():
        source = pathlib.Path(directory) / f"{name}.hs"
        source.write_text(PRELUDE + body)
        result = subprocess.run(
            ["cabal", "exec", "--", "ghc", "-fno-code", "-hide-all-packages", "-package", "base", "-package", "cometa", str(source)],
            capture_output=True, text=True, check=False,
        )
        if (result.returncode == 0) != should_compile:
            raise SystemExit(f"{name}: unexpected compiler result\n{result.stdout}{result.stderr}")
        if not should_compile and "Couldn't match type" not in result.stderr:
            raise SystemExit(f"{name}: failed for an unexpected reason\n{result.stderr}")
print("Handler capability control and two compile-fail checks passed")
