"""Published verification must resolve packages without checkout/native paths."""

import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("consumer", ROOT / "tools/check-source-package.py")
consumer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(consumer)


class PublishedConsumerTest(unittest.TestCase):
    def test_published_version_is_resolved_without_local_library_sources(self):
        calls = []

        def run(command, cwd, env, check):
            configuration = (cwd / "cabal.project").read_text()
            self.assertIn("constraints: cometa == 0.1.0.0", configuration)
            self.assertIn("flags: -system-cardano-c", configuration)
            self.assertNotIn("extra-include-dirs", configuration)
            self.assertNotIn("extra-lib-dirs", configuration)
            self.assertNotIn(str(ROOT), configuration)
            self.assertEqual(env["GHC_ENVIRONMENT"], "-")
            self.assertEqual(sorted(path.name for path in cwd.iterdir()), ["cabal.project", "consumer"])
            self.assertTrue(check)
            calls.append(command)

        with patch("sys.argv", ["check-source-package.py", "--published-version", "0.1.0.0"]), patch.object(consumer.subprocess, "run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            consumer.main()
        self.assertEqual(calls, [["cabal", "update"], ["cabal", "build", "exe:package-consumer"], ["cabal", "run", "exe:package-consumer"]])

    def test_published_mode_rejects_local_or_unsafe_inputs(self):
        for args in (["--published-version", "0.1.0.0", "local.tar.gz"],
                     ["--published-version", "0.1.0.0", "--offline"],
                     ["--published-version", "0.1.0.0\nconstraints: base < 1"]):
            with self.subTest(args=args), patch("sys.argv", ["check-source-package.py", *args]), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    consumer.main()
                self.assertEqual(result.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
