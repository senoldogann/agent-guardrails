#!/usr/bin/env bash
# Integration test: Python template (pytest + Hypothesis + pytest-reportlog) through the evidence pipeline.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project python
cd "$project"
cat >pyproject.toml <<'EOF'
[project]
name = "lang-py"
version = "0.0.0"
requires-python = ">=3.12"

[tool.pytest.ini_options]
pythonpath = ["src"]
testpaths = ["tests"]
EOF
uv add -q --dev pytest hypothesis pytest-reportlog ruff mutmut >"$project/.setup.log" 2>&1 || {
  cat "$project/.setup.log"
  exit 1
}
mkdir -p src/pkg tests/property
touch src/pkg/__init__.py

cat >tests/property/test_percent.py <<'EOF'
from decimal import Decimal

import pytest
from hypothesis import Phase, given, settings, strategies as st

from pkg.percent import NegativePercentError, make_percent

PINNED = settings(max_examples=200, phases=tuple(Phase), database=None, deadline=None)


@PINNED
@given(st.decimals(min_value=0, max_value=100, allow_nan=False, allow_infinity=False))
def test_ac1_accepts_range_and_preserves_value(raw: Decimal) -> None:
    assert make_percent(raw) == raw


@PINNED
@given(st.decimals(max_value=Decimal("-0.0000001"), allow_nan=False, allow_infinity=False))
def test_ac2_rejects_negative(raw: Decimal) -> None:
    with pytest.raises(NegativePercentError):
        make_percent(raw)
EOF
cat >tests/test_other.py <<'EOF'
def test_unit_arithmetic() -> None:
    assert 1 + 1 == 2
EOF

write_errors() {
  cat >src/pkg/percent.py <<EOF
from decimal import Decimal

$1


class NegativePercentError(ValueError):
    pass


class PercentAbove100Error(ValueError):
    pass


def make_percent(raw: Decimal) -> Decimal:
$2
EOF
}
write_stub() { write_errors "" '    raise NotImplementedError("NotImplemented: make_percent")'; }
write_correct() {
  write_errors "" '    if raw < 0:
        raise NegativePercentError(str(raw))
    if raw > 100:
        raise PercentAbove100Error(str(raw))
    return raw'
}
write_wrong() {
  write_errors "" '    if raw < 0:
        raise NegativePercentError(str(raw))
    return raw.quantize(Decimal(1))'
}
write_skip() { write_errors "import pytest" '    pytest.skip("not today")'; }
write_profile_override() {
  write_errors 'from hypothesis import Phase, settings

settings.register_profile("lazy", phases=[Phase.explicit])
settings.load_profile("lazy")' '    return raw.quantize(Decimal(1))'
}
write_report_patch() {
  write_errors 'import _pytest.reports as reports

_original = reports.TestReport.__init__


def _passing(self, *args, **kwargs):
    _original(self, *args, **kwargs)
    if self.outcome == "failed":
        self.outcome = "passed"
        self.longrepr = None


reports.TestReport.__init__ = _passing' '    return raw.quantize(Decimal(1))'
}

write_report_log_forgery() {
  # shellcheck disable=SC2016 # Python source; "$report_type" is a JSON key, not a shell expansion
  write_errors 'import json
import os
import sys

_log = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--report-log="))
with open(_log, "w") as _out:
    for _test in ("test_ac1_accepts_range_and_preserves_value", "test_ac2_rejects_negative"):
        _record = {"nodeid": "tests/property/test_percent.py::" + _test, "when": "call", "outcome": "passed"}
        _out.write(json.dumps({"$report_type": "TestReport", **_record}) + "\n")
os.execlp("true", "true")' '    return raw.quantize(Decimal(1))'
}
restriction_lint() {
  uv run ruff check --no-cache --config .agent/lint/ruff-restrictions.toml src
}

echo "python:"
write_stub
lock_tests tests/property/test_percent.py <<'EOF'
tests/property/test_percent.py::test_ac1_accepts_range_and_preserves_value
tests/property/test_percent.py::test_ac2_rejects_negative
EOF
run_red_green write_stub write_correct write_wrong

write_skip
expect_failure "pytest.skip in implementation: verify-green fails" sh -c 'make --no-print-directory test; .agent/bin/verify-green T-1'
expect_result "pytest.skip in implementation: reported as skipped" \
  tests/property/test_percent.py::test_ac1_accepts_range_and_preserves_value skipped "not today"

write_profile_override
expect_failure "Hypothesis profile override: verify-green fails" sh -c 'make --no-print-directory test; .agent/bin/verify-green T-1'
expect_result "Hypothesis profile override: integrity guard reports it" \
  tests/property/test_percent.py::test_ac1_accepts_range_and_preserves_value error "hypothesis.settings.default"

write_report_patch
expect_failure "TestReport patch: verify-green fails" sh -c 'make --no-print-directory test; .agent/bin/verify-green T-1'
expect_result "TestReport patch: integrity guard reports it past the patched reporting" \
  "(integrity)::(integrity)" error "_pytest.reports.TestReport.__init__"

write_report_log_forgery
expect_failure "report-log forgery (sys.argv + os.execlp): restriction lint rejects it" restriction_lint
expect_output "report-log forgery: lint bans os" "\`os\` is banned"
expect_output "report-log forgery: lint bans sys" "\`sys\` is banned"

write_correct
expect_success "correct: restriction lint passes" restriction_lint

# Mutation gate inputs: mutmut (it mutates numeric literals itself) over a scoped file.
write_correct
cat >src/pkg/discount.py <<'EOF'
def discount_minor(subtotal: int, percent: int) -> int:
    """Rounded discount in minor units: round_half_up(subtotal * percent / 100)."""
    return (subtotal * percent + 50) // 100
EOF
cat >tests/property/test_discount.py <<'EOF'
from pkg.discount import discount_minor

TABLE = [(1234, 15, 185), (49, 1, 0), (50, 1, 1), (0, 100, 0)]


def test_ac1_rounds_half_up_at_the_boundaries() -> None:
    for subtotal, percent, expected in TABLE:
        assert discount_minor(subtotal, percent) == expected
EOF
lock_file_tests M-1 tests/property/test_discount.py
run_mutation "strong suite" src/pkg/discount.py
expect_all_killed "strong suite: zero non-killed mutants"
expect_mutant "strong suite: mutmut kills + 50 -> + 51" killed "+ 51"

cat >tests/property/test_discount.py <<'EOF'
from pkg.discount import discount_minor


def test_ac1_returns_an_int() -> None:
    assert isinstance(discount_minor(1234, 15), int)
EOF
cat >tests/test_discount_extra.py <<'EOF'
from pkg.discount import discount_minor


def test_unit_rounds_half_up_not_locked() -> None:
    assert discount_minor(49, 1) == 0
    assert discount_minor(50, 1) == 1
    assert discount_minor(1234, 15) == 185
EOF
lock_file_tests M-1 tests/property/test_discount.py
run_mutation "weak locked suite" src/pkg/discount.py
expect_mutant "weak locked suite: + 50 -> + 51 survives (unlocked tests do not count)" survived "+ 51"
rm tests/test_discount_extra.py

finish python
