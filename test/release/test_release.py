"""Offline release gates: synthetic archives, manifests, and mocked uploads."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError


SPEC = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[2] / "tools/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
SHA = "a" * 40
PIN = "b" * 40


def make_archive(path, files):
    with tarfile.open(path, "w:gz") as archive:
        for name, content in files.items():
            data = content.encode()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "native").mkdir()
        (self.root / "native/package.json").write_text(json.dumps({"name": "cardano-c-clib", "version": "2.3.4.0"}))
        (self.root / "native/cardano-c.ref").write_text(PIN + "\n")
        (self.root / "cometa.cabal").write_text("name: cometa\nversion: 1.2.0.0\n")
        self.directory = self.root / "artifacts"
        self.directory.mkdir()
        self.native_name = "cardano-c-clib-2.3.4.0.tar.gz"
        self.cometa_name = "cometa-1.2.0.0.tar.gz"
        self.docs_name = "cometa-1.2.0.0-docs.tar.gz"
        self.native_files = {"cardano-c-clib-2.3.4.0/cardano-c-clib.cabal": "name: cardano-c-clib\nversion: 2.3.4.0\n",
                             "cardano-c-clib-2.3.4.0/NATIVE_REVISION": PIN + "\n"}
        self.cometa_files = {"cometa-1.2.0.0/cometa.cabal": "name: cometa\nversion: 1.2.0.0\n  build-depends: cardano-c-clib ==2.3.4.0\n",
                            "cometa-1.2.0.0/native/cardano-c.ref": PIN + "\n"}
        make_archive(self.directory / self.native_name, self.native_files)
        make_archive(self.directory / self.cometa_name, self.cometa_files)
        make_archive(self.directory / self.docs_name, {"cometa-1.2.0.0-docs/index.html": "documentation"})
        self.env = {"GITHUB_SHA": SHA, "GITHUB_REF": "refs/heads/main", "HACKAGE_TOKEN": "test-secret-never-log"}
        self.root_patch = patch.object(release, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.revision_patch = patch.object(release.subprocess, "run", return_value=Mock(stdout=SHA + "\n"))
        self.revision_patch.start()
        self.addCleanup(self.revision_patch.stop)

    def prepare(self, mode="candidate"):
        with contextlib.redirect_stdout(io.StringIO()):
            return release.prepare(self.directory, mode, self.env)

    def test_prepare_records_hashes_revisions_and_workflow_version(self):
        self.env["GITHUB_OUTPUT"] = str(self.root / "output")
        manifest = self.prepare()
        self.assertEqual(manifest["source_revision"], SHA)
        self.assertEqual(manifest["native_revision"], PIN)
        self.assertEqual((self.root / "output").read_text(), "version=1.2.0.0\n")
        self.assertEqual(release.validate_manifest(self.directory, "candidate", self.env), manifest)
        self.assertIn("manifest.json", (self.directory / "SHA256SUMS").read_text())

    def test_changed_archives_manifest_or_checksum_are_rejected(self):
        for name in (self.docs_name, "manifest.json", "SHA256SUMS"):
            with self.subTest(name=name):
                self.prepare()
                path = self.directory / name
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                with self.assertRaises(release.ReleaseError):
                    release.validate_manifest(self.directory, "candidate", self.env)
                path.write_bytes(original)

    def test_publish_requires_exact_existing_version_tag_and_commit(self):
        for ref in ("refs/heads/main", "refs/tags/v1.2.0.1", "refs/tags/1.2.0.0"):
            self.env["GITHUB_REF"] = ref
            with self.subTest(ref=ref), self.assertRaises(release.ReleaseError):
                self.prepare("publish")
        self.env["GITHUB_REF"] = "refs/tags/v1.2.0.0"
        self.prepare("publish")
        self.env["GITHUB_SHA"] = "c" * 40
        with self.assertRaises(release.ReleaseError):
            release.validate_manifest(self.directory, "publish", self.env)

    def test_native_pin_and_exact_dependency_and_package_version_are_required(self):
        cases = [
            (self.native_name, {**self.native_files, "cardano-c-clib-2.3.4.0/NATIVE_REVISION": "c" * 40 + "\n"}),
            (self.cometa_name, {**self.cometa_files, "cometa-1.2.0.0/cometa.cabal": "name: cometa\nversion: 1.2.0.0\n  build-depends: cardano-c-clib >=2.3.4.0\n"}),
            (self.cometa_name, {**self.cometa_files, "cometa-1.2.0.0/cometa.cabal": "name: cometa\nversion: 9.0\n  build-depends: cardano-c-clib ==2.3.4.0\n"}),
        ]
        for name, files in cases:
            with self.subTest(name=name):
                make_archive(self.directory / name, files)
                with self.assertRaises(release.ReleaseError):
                    self.prepare()
                make_archive(self.directory / self.native_name, self.native_files)
                make_archive(self.directory / self.cometa_name, self.cometa_files)

    def test_upload_order_and_candidate_flags(self):
        self.prepare()
        with patch.object(release, "published_hash", return_value=None), patch.object(release, "cabal_upload") as upload:
            with contextlib.redirect_stdout(io.StringIO()):
                release.upload(self.directory, "candidate", self.env)
            self.assertEqual([call.args[0].name for call in upload.call_args_list],
                             [self.native_name, self.cometa_name, self.docs_name])
            self.assertTrue(upload.call_args_list[2].kwargs["documentation"])

    def test_identical_published_native_is_reused_for_candidates(self):
        manifest = self.prepare()
        with patch.object(release, "published_hash", side_effect=[manifest["files"][self.native_name]["sha256"], None]), patch.object(release, "cabal_upload") as upload:
            with contextlib.redirect_stdout(io.StringIO()):
                release.upload(self.directory, "candidate", self.env)
            self.assertEqual([call.args[0].name for call in upload.call_args_list], [self.cometa_name, self.docs_name])

    def test_identical_published_sources_skip_on_retry(self):
        self.env["GITHUB_REF"] = "refs/tags/v1.2.0.0"
        manifest = self.prepare("publish")
        with patch.object(release, "published_hash", side_effect=[manifest["files"][name]["sha256"] for name in (self.native_name, self.cometa_name)]), patch.object(release, "cabal_upload") as upload:
            with contextlib.redirect_stdout(io.StringIO()):
                release.upload(self.directory, "publish", self.env)
            self.assertEqual(upload.call_count, 1)
            self.assertEqual(upload.call_args.args[0].name, self.docs_name)

    def test_candidate_for_published_cometa_is_rejected_before_upload(self):
        manifest = self.prepare()
        with patch.object(release, "published_hash", side_effect=[None, manifest["files"][self.cometa_name]["sha256"]]), patch.object(release, "cabal_upload") as upload:
            with self.assertRaises(release.ReleaseError):
                release.upload(self.directory, "candidate", self.env)
            upload.assert_not_called()

    def test_published_mismatch_prevents_any_upload(self):
        self.prepare()
        for results in (["0" * 64], [None, "0" * 64]):
            with self.subTest(results=results), patch.object(release, "published_hash", side_effect=results), patch.object(release, "cabal_upload") as upload:
                with self.assertRaises(release.ReleaseError):
                    release.upload(self.directory, "candidate", self.env)
                upload.assert_not_called()

    def test_missing_token_prevents_network_calls(self):
        self.prepare()
        self.env.pop("HACKAGE_TOKEN")
        with patch.object(release, "published_hash") as lookup, self.assertRaises(release.ReleaseError):
            release.upload(self.directory, "candidate", self.env)
        lookup.assert_not_called()

    def test_changed_artifact_prevents_network_calls(self):
        self.prepare()
        with (self.directory / self.docs_name).open("ab") as archive:
            archive.write(b"changed")
        with patch.object(release, "published_hash") as lookup, self.assertRaises(release.ReleaseError):
            release.upload(self.directory, "candidate", self.env)
        lookup.assert_not_called()

    def test_missing_documentation_and_unsafe_archive_fail_closed(self):
        (self.directory / self.docs_name).unlink()
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        make_archive(self.directory / self.docs_name, {"cometa-1.2.0.0-docs/index.html": "docs"})
        make_archive(self.directory / self.native_name, {**self.native_files, "../outside": "invalid"})
        with self.assertRaises(release.ReleaseError):
            self.prepare()


class UploadBoundaryTests(unittest.TestCase):
    def test_upload_failure_reports_server_reason_without_token(self):
        failure = subprocess.CalledProcessError(
            1, ["cabal", "--token=private-token"],
            output="Uploading with --token=private-token",
            stderr="HTTP 403 Forbidden: account is not an uploader. private-token")
        with patch.object(release.subprocess, "run", side_effect=failure):
            with self.assertRaises(release.ReleaseError) as caught:
                release.cabal_upload(Path("native.tar.gz"), "candidate", "private-token")
        message = str(caught.exception)
        self.assertIn("HTTP 403 Forbidden: account is not an uploader", message)
        self.assertIn("exit 1", message)
        self.assertNotIn("private-token", message)
        self.assertIn("[REDACTED]", message)

    def test_upload_diagnostics_redact_encoded_tokens_and_limit_output(self):
        token = "credential/with+punctuation"
        failure = subprocess.CalledProcessError(
            1, [], output=release.quote(token, safe=""),
            stderr="\x1b[31mcredential/with+\x1b[0mpunctuation\n::error::response\n" + "x" * 5000)
        message = release.upload_diagnostics(failure, token)
        self.assertNotIn(token, message)
        self.assertNotIn(release.quote(token, safe=""), message)
        self.assertNotIn("\n", message)
        self.assertNotIn("\x1b", message)
        self.assertLessEqual(len(message), 4000)
        self.assertIn("[REDACTED]", message)

    def test_upload_failure_without_output_or_executable_is_actionable(self):
        failures = [
            (subprocess.CalledProcessError(1, []), "No diagnostic output"),
            (FileNotFoundError("credential"), "Cannot start Cabal"),
        ]
        for failure, expected in failures:
            with self.subTest(expected=expected), patch.object(release.subprocess, "run", side_effect=failure):
                with self.assertRaises(release.ReleaseError) as caught:
                    release.cabal_upload(Path("native.tar.gz"), "candidate", "credential")
                self.assertIn(expected, str(caught.exception))
                self.assertNotIn("credential", str(caught.exception))

    def test_cabal_flags_and_secret_safe_failure(self):
        for mode in ("candidate", "publish"):
            with patch.object(release.subprocess, "run") as run:
                release.cabal_upload(Path("cometa-docs.tar.gz"), mode, "secret", documentation=True)
                command = run.call_args.args[0]
                self.assertEqual("--publish" in command, mode == "publish")
                self.assertIn("--documentation", command)
                self.assertIn("--token=secret", command)
        failure = subprocess.CalledProcessError(1, ["cabal", "--token=secret"], stderr="secret")
        with patch.object(release.subprocess, "run", side_effect=failure):
            with self.assertRaises(release.ReleaseError) as caught:
                release.cabal_upload(Path("cometa-docs.tar.gz"), "publish", "secret", documentation=True)
            self.assertNotIn("secret", str(caught.exception))
            self.assertIsNone(caught.exception.__cause__)

    def test_main_redacts_supplied_token_in_errors(self):
        stderr = io.StringIO()
        with patch.object(release, "upload", side_effect=release.ReleaseError("secret cannot be shown")), contextlib.redirect_stderr(stderr):
            status = release.main(["upload", "--mode", "candidate"], {"HACKAGE_TOKEN": "secret"})
        self.assertEqual(status, 1)
        self.assertNotIn("secret", stderr.getvalue())

    def test_hackage_only_404_is_absent_and_download_hash_is_exact(self):
        response = Mock(status=200)
        response.read.side_effect = [b"archive", b""]
        manager = Mock()
        manager.__enter__ = Mock(return_value=response)
        manager.__exit__ = Mock(return_value=False)
        with patch.object(release, "urlopen", return_value=manager) as open_url:
            self.assertEqual(release.published_hash("cometa", "1.2"), hashlib.sha256(b"archive").hexdigest())
            self.assertEqual(open_url.call_args.args[0], "https://hackage.haskell.org/package/cometa-1.2/cometa-1.2.tar.gz")
        for code in (404, 403, 500):
            with patch.object(release, "urlopen", side_effect=HTTPError("https://example.test", code, "failure", None, None)):
                if code == 404:
                    self.assertIsNone(release.published_hash("cometa", "1.2"))
                else:
                    with self.assertRaises(release.ReleaseError):
                        release.published_hash("cometa", "1.2")
        with patch.object(release, "urlopen", side_effect=URLError("offline")), self.assertRaises(release.ReleaseError):
            release.published_hash("cometa", "1.2")


if __name__ == "__main__":
    unittest.main()
