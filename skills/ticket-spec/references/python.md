# Python spec patterns

Tools: uv, basedpyright strict, ruff, pytest, Hypothesis, pytest-reportlog (results evidence).
`pyproject.toml` sets `[tool.pytest.ini_options] testpaths = ["tests"]` and, for a src layout,
`pythonpath = ["src"]`. The Makefile loads `.agent/test-support/pytest_integrity.py`, which turns
tests into errors once implementation code patches pytest, pytest-reportlog or Hypothesis'
settings. Domain code under `src/` also passes `.agent/lint/ruff-restrictions.toml`: no test
frameworks, `atexit`, `importlib`, `eval`/`exec`, `builtins`, `ctypes`, and none of the modules
`os`, `sys`, `subprocess`, `multiprocessing`, `signal`, `pty`, `pathlib`, `io`, `shutil`, `tempfile`,
`socket`. With them, code under test can read the report-log path from `sys.argv`, write a passing
log and `exec` away before pytest reports.

Adapters that need I/O (files, environment, processes, network) live outside the restricted path,
in a separate adapter package (for example `adapters/<pkg>_io/`). Writing one is a separate
write-allow entry that the owner reviews explicitly; the domain package never imports it, the
adapter imports the domain.

Python cannot make a constructor private, so the guarantee is: the type checker rejects mixing
raw values with branded ones, and `escape-check py` + review keep raw construction inside the
implementation module. Say this in open questions if the ticket needs a hard guarantee.

## Contract (locked): `src/<pkg>/domain/percent_contract.py`

```python
from decimal import Decimal
from typing import NewType, Protocol

Percent = NewType("Percent", Decimal)
"""A percentage in [0, 100]. Only `make_percent` produces one."""


class PercentError(ValueError):
    """Base error for invalid percentages."""


class NegativePercentError(PercentError): ...


class PercentAbove100Error(PercentError): ...


class NonFinitePercentError(PercentError): ...


class MakePercent(Protocol):
    def __call__(self, raw: Decimal, /) -> Percent: ...
```

## Implementation stub (write-allowed): `src/<pkg>/domain/percent.py`

The message must start with `NotImplemented:` (the spec gate checks every locked test fails with it).

```python
from decimal import Decimal

from .percent_contract import MakePercent, Percent


def make_percent(raw: Decimal) -> Percent:
    """Validate `raw` and brand it; raises a PercentError subclass on invalid input."""
    raise NotImplementedError("NotImplemented: make_percent")


_contract: MakePercent = make_percent  # type checker verifies the signature against the contract
```

## Property test (locked): `tests/property/test_percent.py`

- Name every test `test_ac<n>_<behaviour>`, one criterion per test; the ID is `<file>::<function>`.
- Pin the run configuration with an explicit `@settings(...)` on every property test. It overrides
  any profile, so a `settings.load_profile(...)` elsewhere cannot shrink the run.
- `@pytest.mark.parametrize` in locked tests needs explicit `ids=[...]`; generated ids such as
  `x1` or `1.5` are not stable test IDs.

```python
from decimal import Decimal

import pytest
from hypothesis import Phase, example, given, settings, strategies as st

from pkg.domain.percent import make_percent
from pkg.domain.percent_contract import NegativePercentError

PINNED = settings(max_examples=200, phases=tuple(Phase), database=None, deadline=None)


@PINNED
@given(st.decimals(min_value=0, max_value=100, allow_nan=False, allow_infinity=False))
@example(Decimal(0))
@example(Decimal("-0"))
@example(Decimal(100))
def test_ac1_accepts_range_and_preserves_value(raw: Decimal) -> None:
    assert make_percent(raw) == raw


@PINNED
@given(st.decimals(max_value=Decimal("-0.0000001"), allow_nan=False, allow_infinity=False))
def test_ac2_rejects_negative(raw: Decimal) -> None:
    with pytest.raises(NegativePercentError):
        make_percent(raw)
```

Edge values via `@example(...)` on the criterion they belong to: `Decimal("100.0000001")` for
above-100, `Decimal("NaN")` and `Decimal("Infinity")` for not-finite, `None` where an Optional
enters the boundary.

## Acceptance

One pytest function per acceptance scenario in `tests/acceptance/test_<id>.py` (locked), named
`test_ac<n>_<scenario>`, with Given/When/Then as comments. A `specs/<ID>/*.feature` file is optional
documentation; the kit ships no Gherkin runner.
