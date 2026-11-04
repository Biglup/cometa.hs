#!/usr/bin/env python3
"""Inventory the pinned public C headers with Clang; preserve hand-reviewed mapping columns.

Usage: python3 tools/native-inventory.py /path/to/cardano-c [--write]
Default checks the committed inventory and content pin. Requires Python 3 and Clang.
This is an inventory tool, not an FFI generator or ownership-contract inference engine.
"""
import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COLUMNS = ["c_symbol", "header", "kind", "c_type", "planned_phase", "haskell_api",
           "visibility", "ownership", "status", "tests", "omission_rationale"]
PHASES = {"crypto": "P04", "key_handlers": "P04", "address": "P05", "assets": "P05",
          "common": "P05", "metadata": "P06", "plutus_data": "P06", "scripts": "P06",
          "certs": "P07", "pool_params": "P07", "protocol_params": "P07",
          "proposal_procedures": "P07", "voting_procedures": "P07", "transaction": "P08",
          "witness_set": "P08", "transaction_body": "P08", "auxiliary_data": "P08", "providers": "P09",
          "message_signing": "P04",
          "transaction_builder": "P10", "cbor": "P03", "json": "P03", "encoding": "P03",
          "uplc": "P11", "network": "P09"}


def phase(header, name):
    if "blockfrost" in header:
        return "P13"
    if "deferred_redeemer" in name or "/evaluation/" in header:
        return "P11"
    if any(x in name for x in ("sub_transaction", "balance_interval", "account_balance", "guard")):
        return "P12"
    if "_impl" in header or "coin_selector" in header:
        return "P09"
    part = header.split("/")[3]
    return PHASES.get(part, "P04" if part == "bip39.h" else "P10" if part in ("slot_config.h", "time.h") else "P02")


def inventory(native, headers):
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / "inventory.c"
        source.write_text("".join(f'#include <{p.relative_to(native / "lib/include").as_posix()}>\n'
                                  for p in headers))
        result = subprocess.run(["clang", "-x", "c", "-std=c11", "-I", str(native / "lib/include"),
                                 "-Xclang", "-ast-dump=json", "-fsyntax-only", str(source)],
                                check=True, capture_output=True, text=True)
        nodes = json.loads(result.stdout)["inner"]
    rows = {}
    current_file = ""

    def add(name, header, kind, c_type):
        key = (name, kind)
        row = rows.setdefault(key, {"c_symbol": name, "header": set(), "kind": kind, "c_type": c_type})
        row["header"].add(header)
        # Prefer the complete declaration's header over forward declarations during later review.
        if kind == "type" and "{" in c_type:
            row["c_type"] = c_type

    for node in nodes:
        loc = node.get("loc", {})
        current_file = loc.get("file", current_file)
        if not current_file.startswith(str(native / "lib/include") + "/"):
            continue
        header = Path(current_file).relative_to(native).as_posix()
        name = node.get("name", "")
        kind = node["kind"]
        c_type = node.get("type", {}).get("qualType", "")
        if kind == "FunctionDecl":
            parameters = [f'{x.get("type", {}).get("qualType", "")} {x.get("name", "")}'.strip()
                          for x in node.get("inner", []) if x["kind"] == "ParmVarDecl"]
            add(name, header, "function", c_type + "; parameters: " + ", ".join(parameters))
        elif kind == "TypedefDecl":
            add(name, header, "callback" if "(*)" in c_type else "enum" if c_type.startswith("enum ")
                else "type", c_type)
        elif kind == "EnumDecl":
            value = -1
            for child in node.get("inner", []):
                if child["kind"] == "EnumConstantDecl":
                    explicit = next((x.get("value") for x in child.get("inner", [])
                                     if x["kind"] == "ConstantExpr"), None)
                    value = int(explicit) if explicit is not None else value + 1
                    add(child["name"], header, "enum_variant", str(value))
        elif kind == "RecordDecl" and name:
            for child in node.get("inner", []):
                if child["kind"] == "FieldDecl":
                    add(name + "." + child["name"], header, "field", child["type"]["qualType"])
    for path in headers:
        # Preprocessor constants do not appear in the AST. Exclude ABI decoration macros.
        for match in re.finditer(r"^#define\s+(CARDANO_\w+)\s+([^\n]+)", path.read_text(), re.M):
            if match[1] not in ("CARDANO_EXPORT", "CARDANO_NODISCARD"):
                add(match[1], path.relative_to(native).as_posix(), "constant", match[2].strip())
    for row in rows.values():
        row["header"] = ";".join(sorted(row["header"]))
    return sorted(rows.values(), key=lambda row: (row["header"], row["kind"], row["c_symbol"]))


def manifest(native, paths):
    return {p.relative_to(native).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    native = args.native.resolve()
    pin = (ROOT / "native/cardano-c.ref").read_bytes()
    if not re.fullmatch(rb"[0-9a-f]{40}\n", pin):
        parser.error("native/cardano-c.ref must contain one complete lowercase commit SHA")
    headers = sorted((native / "lib/include").rglob("*.h"))
    if not headers:
        parser.error("no public headers found")
    rows = inventory(native, headers)
    ledger = ROOT / "docs/development/native-api.csv"
    baseline = ROOT / "docs/development/native-baseline.json"
    previous = list(csv.DictReader(ledger.open())) if ledger.exists() else []
    prior = {(r["c_symbol"], r["kind"]): r for r in previous}
    for row in rows:
        name = row["c_symbol"]
        internal = (row["header"].endswith(("/object.h", "/export.h", "/typedefs.h")) or
                    bool(re.search(r"_(?:unref|ref|refcount|set_last_error|get_last_error)$", name)))
        row.update(planned_phase=phase(row["header"].split(";")[0], name), haskell_api="",
                   visibility="internal" if internal else "public", ownership=(
                       "value; no native resource lifetime" if row["kind"] in ("enum", "enum_variant", "constant")
                       else "pending callback lifetime/exception/transfer audit" if row["kind"] == "callback"
                       else "pending argument/result/buffer contract audit" if row["kind"] == "function"
                       else "pending representation/lifetime audit"),
                   status="pending", tests="", omission_rationale=(
                       "Native lifetime/error/ABI plumbing will remain private; bridge pending." if internal else ""))
        old = prior.get((name, row["kind"]), {})
        for key in COLUMNS[4:]:
            row[key] = old.get(key, row[key])
    corpus = sorted(p for p in (native / "lib/tests/vectors/bindings/v1").rglob("*") if p.is_file())
    metadata = {"schema_version": 1, "native_repository": "https://github.com/Biglup/cardano-c",
                "native_commit_ref": "native/cardano-c.ref",
                "native_commit_ref_sha256": hashlib.sha256(pin).hexdigest(),
                "native_version": (native / "VERSION").read_text().strip(),
                "source_provenance": "Source content at native/cardano-c.ref; verify using the manifests below",
                "content_verification": "Check mode compares the header/corpus SHA256 manifests; native/cardano-c.ref supplies revision provenance",
                "reproduce": "python3 tools/native-inventory.py /path/to/cardano-c (Python 3 and Clang; maintainer tool only)",
                "ledger_policy": {
                    "status": "pending means unimplemented or unverified; implemented requires an existing binding and passing named tests; adapted provides the native capability through a tested Haskell-owned operation rather than a direct C call; internal visibility alone is not completion",
                    "haskell_api": "blank until the public API or internal bridge is decided",
                    "tests": "blank until actual binding tests exist and pass",
                    "ownership": "pending audit is explicit; C type and parameter names identify the header contract to review, including buffers",
                    "planned_phase": "provisional domain grouping from IMPLEMENTATION_PLAN.md, not a completion claim",
                    "header": "semicolon-separated declaration headers; repeated forward declarations are deduplicated by symbol and kind",
                    "public": "domain capability or value; final Haskell presentation remains undecided",
                    "internal": "native lifecycle, error-storage and ABI plumbing kept private; implementation still pending"},
                "exclusions": ["System and bundled dependency headers outside lib/include",
                               "C preprocessor include guards and CARDANO_EXPORT/CARDANO_NODISCARD ABI decoration",
                               "Opaque struct tags are represented by their public typedef, not counted twice",
                               "Declarations missing CARDANO_EXPORT are retained because they occur in public headers",
                               "No domain operation omitted; undecided mappings remain pending"],
                "inventory_scope": "All lib/include/**/*.h; unique declarations, enum variants, public fields and API constants",
                "inventory_counts": dict(sorted(collections.Counter(r["kind"] for r in rows).items())),
                "headers_sha256": manifest(native, headers), "conformance_corpus_path": "lib/tests/vectors/bindings/v1",
                "conformance_corpus_sha256": manifest(native, corpus)}
    if args.write:
        with ledger.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=COLUMNS, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
        baseline.write_text(json.dumps(metadata, indent=2) + "\n")
    else:
        if rows != previous or metadata != json.loads(baseline.read_text()):
            raise SystemExit("Inventory or source content differs; review the baseline before using --write.")
    print(f'{len(headers)} headers; {len(rows)} entries: {metadata["inventory_counts"]}')


if __name__ == "__main__":
    main()
