#!/usr/bin/env python3
"""Check credential role boundaries through the public package interface."""
import pathlib
import subprocess
import tempfile

PRELUDE = """module Boundary where
import qualified Cometa.Address.Shelley as Address
import qualified Cometa.Address.Reward as Reward
import Cometa.Credential
import Data.Coerce (coerce)
"""
CASES = {
    "Valid": (True, "valid :: Credential Payment -> Credential Stake -> Address.Address\nvalid = Address.base Address.testnet\n"),
    "ValidReward": (True, "valid :: Credential Stake -> Reward.RewardAddress\nvalid = Reward.fromCredential Address.testnet\n"),
    "RewardDestination": (False, "invalid :: Reward.RewardAddress -> Address.Address\ninvalid = id\n"),
    "HashCoercion": (False, "invalid :: KeyHash Payment -> KeyHash Stake\ninvalid = coerce\n"),
    "CredentialCoercion": (False, "invalid :: Credential Payment -> Credential Stake\ninvalid = coerce\n"),
    "SwappedRoles": (False, "invalid :: Credential Stake -> Credential Payment -> Address.Address\ninvalid = Address.base Address.testnet\n"),
}
with tempfile.TemporaryDirectory(prefix="cometa-credential-roles-") as directory:
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
print("Address role controls and four compile-fail checks passed")
