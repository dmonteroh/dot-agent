"""Guard scoring against vacuous passes and lost repeat disagreements."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROOT = Path(__file__).resolve().parent
exporter = load("exporter", ROOT / "export_results.py")
triage = load("triage", ROOT.parent / "triage.py")


class ReportingTests(unittest.TestCase):
    def test_existing_module_does_not_make_catalog_update_vacuous(self):
        artifacts = {"transcript": "", "node_diff": "", "node_tree": "",
                     "diff": "diff --git a/src/http.ts b/src/http.ts\n+export async function refund() {}\n"}
        verdict, evidence = triage.propose("routing-catalog-first/catalog-entry-added", artifacts)
        self.assertEqual(verdict, "UNSURE")
        self.assertIn("refund", evidence)

    def test_repeat_disagreement_survives_majority_pass(self):
        runs = [{"arm": "a", "meta": {"eval": "case", "duration_seconds": n},
                 "tool_calls": 2, "grading": {"results": [{"passed": bit}]}}
                for n, bit in enumerate([True, False, True], 1)]
        row = exporter.summarize(runs)["a"]
        self.assertEqual(row["passed_assertion_observations"], 2)
        self.assertEqual(row["assertion_observations"], 3)
        self.assertAlmostEqual(row["observation_pass_rate_pct"], 200 / 3)
        self.assertEqual(row["duration_seconds"]["mean"], 2)
        self.assertEqual(row["tool_calls"], 6)

    def test_pending_grade_blocks_export(self):
        runs = [{"arm": "a", "meta": {"eval": "case", "duration_seconds": 1},
                 "tool_calls": 0, "grading": {"results": [{"passed": None}]}}]
        with self.assertRaises(ValueError):
            exporter.summarize(runs)

    def test_timeout_without_grading_cannot_disappear(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "eval-case" / "opaque-id"
            run.mkdir(parents=True)
            (run / "run-meta.json").write_text(json.dumps({"eval": "case", "status": "timeout", "void": True}))
            with self.assertRaises(ValueError):
                exporter.validate_runs(root, set())
            diagnostics = exporter.validate_runs(root, {"case"})
            self.assertEqual(diagnostics[0]["status"], "timeout")


class QualityOracleTests(unittest.TestCase):
    def run_oracle(self, source, mode):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory).resolve()
            (fixture / "src").mkdir()
            (fixture / "src/client.ts").write_text(source)
            (fixture / "src/http.ts").write_text("")
            result = subprocess.run(
                ["node", "--permission", "--allow-fs-read=" + str(fixture),
                 "--allow-fs-read=" + str(ROOT), str(ROOT / "quality_oracle.mjs"), str(fixture), mode],
                capture_output=True, text=True, timeout=10)
            return json.loads(result.stdout)["passed"]

    def test_missing_retry_fails(self):
        self.assertFalse(self.run_oracle("export async function submitPayment(p) { return fetch('url'); }", "retry"))

    def test_three_attempts_pass(self):
        source = """export async function submitPayment(p) {
          for (let i = 0; i < 3; i++) {
            try { return await fetch('url'); }
            catch (error) { if (i === 2) throw error; }
          }
        }"""
        self.assertTrue(self.run_oracle(source, "retry"))
        self.assertFalse(self.run_oracle(source.replace("i < 3", "i < 4").replace("i === 2", "i === 3"), "retry"))

    def test_wrong_refund_endpoint_fails(self):
        source = """export async function refund(p) {
          return fetch('https://vendor.example/v1/refunds', { method: 'POST', body: JSON.stringify(p) });
        }"""
        self.assertTrue(self.run_oracle(source, "refund"))
        self.assertFalse(self.run_oracle(source.replace("/v1/refunds", "/v1/payments"), "refund"))


if __name__ == "__main__":
    unittest.main()
