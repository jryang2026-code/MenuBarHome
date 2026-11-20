#!/usr/bin/env python3
"""Reject new deadline polling in Swift tests."""

import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts/swift_test_waits_baseline.txt"
PATTERNS = {
    "deadline": re.compile(r"\bContinuousClock\s*\.\s*now\s*\.\s*advanced\s*\(\s*by\s*:"),
    "waitUntil": re.compile(r"\bfunc\s+waitUntil\s*(?=[(<])"),
}


def findings(source):
    return Counter({
        name: len(pattern.findall(source))
        for name, pattern in PATTERNS.items()
    })


def violations(current, allowed):
    return current - allowed


def self_test():
    sample = """private func waitUntil<T>() {
        let deadline = ContinuousClock.now
            .advanced(by: .seconds(1))
    }
    func waitUntilEntered() {}
    await waitUntil { true }
    """
    existing = findings(sample)
    assert existing == Counter(deadline=1, waitUntil=1)
    assert not violations(existing, existing)
    assert not violations(findings(""), existing)
    assert violations(findings(sample * 2), existing) == existing
    assert violations(existing, Counter()) == existing
    print("✅ Swift test wait lint self-test passed")


def main():
    allowed = {
        path: Counter(deadline=int(deadlines), waitUntil=int(helpers))
        for path, deadlines, helpers in (
            line.split() for line in BASELINE.read_text().splitlines()
        )
    }
    failed = False
    for path in sorted((ROOT / "Tests").rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        extra = violations(findings(path.read_text()), allowed.get(relative, Counter()))
        for kind, count in extra.items():
            failed = True
            print(f"{relative}: {count} new {kind} occurrence(s); use StateTestSupport.awaitState or a deterministic gate.")
    return int(failed)


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit(main())
