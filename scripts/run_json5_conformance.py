#!/usr/bin/env python3

import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PARSER_DIR = ROOT
REPORT_PATH = ROOT / "reports" / "json5-conformance-report.json"
JQ_BIN = os.environ.get("JQ", "jq")
SUBPROCESS_TIMEOUT_SEC = 10

EXPECTED_BY_EXT = {
    ".json": True,
    ".json5": True,
    ".js": False,
    ".txt": False,
}


def _fixtures_dir() -> Path:
    fixtures_dir = Path(os.environ.get("JSON5_TESTS_DIR", "json5-tests"))
    if fixtures_dir.is_absolute():
        return fixtures_dir
    return ROOT / fixtures_dir


def main() -> int:
    fixtures_dir = _fixtures_dir()

    if not fixtures_dir.is_dir() or not any(fixtures_dir.iterdir()):
        print(
            f"error: fixtures directory missing or empty: {fixtures_dir}",
            file=sys.stderr,
        )
        print("Run: git submodule update --init --recursive", file=sys.stderr)
        return 2

    results = []
    for dirpath, _, filenames in os.walk(fixtures_dir):
        for filename in filenames:
            ext = Path(filename).suffix
            if ext not in EXPECTED_BY_EXT:
                continue

            fixture_path = Path(dirpath) / filename
            relative_path = fixture_path.relative_to(fixtures_dir).as_posix()
            expect_valid = EXPECTED_BY_EXT[ext]

            # Risk assessment:
            # - Command injection risk: mitigated by passing argv list to subprocess.run.
            # - Resource exhaustion risk: fixtures are local, pinned test data from submodule.
            # - Hung parser risk: timeout bounds per-fixture runtime for CI reliability.
            # - Information leakage risk: output report contains only file paths and parser status.
            try:
                process = subprocess.run(
                    [JQ_BIN, "-Rs", "-L", ".", 'include "json5"; fromjson5'],
                    cwd=PARSER_DIR,
                    input=fixture_path.read_bytes(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=SUBPROCESS_TIMEOUT_SEC,
                    check=False,
                )
                parsed = process.returncode == 0
                stderr_lines = process.stderr.decode("utf-8", "replace").splitlines()[
                    :2
                ]
            except subprocess.TimeoutExpired:
                parsed = False
                stderr_lines = [f"timeout after {SUBPROCESS_TIMEOUT_SEC}s"]

            results.append(
                {
                    "file": relative_path,
                    "expect_valid": expect_valid,
                    "parsed": parsed,
                    "passed": parsed == expect_valid,
                    "stderr": stderr_lines,
                }
            )

    summary = {
        "total": len(results),
        "passed": sum(result["passed"] for result in results),
        "failed": sum(not result["passed"] for result in results),
        "valid_total": sum(result["expect_valid"] for result in results),
        "valid_passed": sum(
            result["expect_valid"] and result["passed"] for result in results
        ),
        "invalid_total": sum((not result["expect_valid"]) for result in results),
        "invalid_passed": sum(
            (not result["expect_valid"]) and result["passed"] for result in results
        ),
    }

    if summary["total"] == 0:
        print(f"error: no fixture files found under {fixtures_dir}", file=sys.stderr)
        print("Run: git submodule update --init --recursive", file=sys.stderr)
        return 2

    report = {
        "summary": summary,
        "failures": [result for result in results if not result["passed"]],
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(summary, indent=2))
    print(f"Wrote report: {REPORT_PATH}")

    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
