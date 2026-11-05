"""Locked test-integrity guard for pytest, loaded by the Makefile with ``-p pytest_integrity``.

Implementation code runs inside the test process, so it can neuter tests: monkeypatch pytest's
reports or outcomes, patch the pytest-reportlog writer, or load a Hypothesis profile that skips
generation. At configure time (before test modules import implementation code) this plugin captures
references to that machinery and Hypothesis' active settings; every test whose setup or teardown
sees a replaced or removed reference becomes an error. Because patched reporting can rewrite those
errors too, the session-end check also appends its own record to the report log after
pytest-reportlog closed it (the results adapter turns it into an ``error`` line) and exits non-zero.
It raises the bar; mutation testing remains the backstop for adaptive tampering.
"""

from __future__ import annotations

import importlib
import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

import pytest
from hypothesis import settings

WATCHED_MODULES: tuple[str, ...] = (
    "pytest",
    "_pytest.reports",
    "_pytest.runner",
    "_pytest.outcomes",
    "_pytest.skipping",
    "_pytest.python",
    "_pytest.python_api",
    "_pytest.raises",
    "_pytest.main",
    "_pytest.terminal",
    "pytest_reportlog.plugin",
    "hypothesis",
    "hypothesis.core",
    "hypothesis._settings",
)
WATCHED_CLASSES: tuple[str, ...] = (
    "TestReport",
    "CollectReport",
    "ReportLogPlugin",
    "settings",
)

type Snapshot = dict[str, object]


class TestMachineryChangedError(Exception):
    """Implementation code replaced part of pytest, pytest-reportlog or Hypothesis during the run."""


def _modules() -> list[ModuleType]:
    return [
        importlib.import_module(name)
        for name in WATCHED_MODULES
        if importlib.util.find_spec(name) is not None
    ]


def _members(owner: object) -> dict[str, object]:
    """Every attribute an owner defines itself (functions, classes, descriptors), by reference."""
    namespace: dict[str, object] = dict(vars(owner))
    return {
        name: value
        for name, value in namespace.items()
        if not isinstance(value, (str, int, float, bool))
    }


def take_snapshot() -> Snapshot:
    """References to every watched attribute plus Hypothesis' active default settings."""
    snapshot: Snapshot = {}
    for module in _modules():
        snapshot.update(
            {
                f"{module.__name__}.{name}": value
                for name, value in _members(module).items()
            }
        )
        for class_name in WATCHED_CLASSES:
            owner: object = getattr(module, class_name, None)
            if isinstance(owner, type) and owner.__module__ == module.__name__:
                snapshot.update(
                    {
                        f"{module.__name__}.{class_name}.{name}": value
                        for name, value in _members(owner).items()
                    }
                )
    snapshot["hypothesis.settings.default"] = settings.default
    return snapshot


def changed_keys(before: Snapshot, after: Snapshot) -> list[str]:
    """Keys whose value is no longer the same object, plus keys that disappeared."""
    return sorted(
        key
        for key, value in before.items()
        if key not in after or after[key] is not value
    )


class IntegrityGuard:
    """Pytest plugin holding the baseline captured before collection."""

    def __init__(self, baseline: Snapshot, report_log: Path | None) -> None:
        self.baseline: Snapshot = baseline
        self.report_log: Path | None = report_log
        self.session_end_changes: list[str] = []

    def check(self, when: str) -> None:
        changed = changed_keys(self.baseline, take_snapshot())
        if changed:
            raise TestMachineryChangedError(
                f"Test integrity violated ({when}): {', '.join(changed)} changed after the session started. "
                + "Implementation code must not modify pytest, pytest-reportlog or Hypothesis."
            )

    @pytest.hookimpl(tryfirst=True)
    def pytest_runtest_setup(self, item: pytest.Item) -> None:
        self.check(f"before {item.nodeid}")

    @pytest.hookimpl(trylast=True)
    def pytest_runtest_teardown(self, item: pytest.Item) -> None:
        self.check(f"after {item.nodeid}")

    @pytest.hookimpl(trylast=True)
    def pytest_sessionfinish(self, session: pytest.Session) -> None:
        self.session_end_changes = changed_keys(self.baseline, take_snapshot())
        if self.session_end_changes:
            _ = sys.stderr.write(
                f"Test integrity violated at session end: {', '.join(self.session_end_changes)}\n"
            )
            session.exitstatus = pytest.ExitCode.INTERNAL_ERROR

    @pytest.hookimpl(trylast=True)
    def pytest_unconfigure(self) -> None:
        """Runs after pytest-reportlog closed its file, so no patched writer can drop this record."""
        if self.session_end_changes and self.report_log is not None:
            record = {
                "$report_type": "CollectReport",
                "nodeid": "(integrity)",
                "outcome": "failed",
                "longrepr": "Test integrity violated at session end: "
                + ", ".join(self.session_end_changes),
            }
            with self.report_log.open("a", encoding="utf-8") as log:
                _ = log.write(json.dumps(record) + "\n")


@pytest.hookimpl(trylast=True)
def pytest_configure(config: pytest.Config) -> None:
    """Capture the baseline after every plugin (including Hypothesis' profile loading) configured."""
    report_log: str | None = config.getoption("report_log", default=None)
    guard = IntegrityGuard(take_snapshot(), Path(report_log) if report_log else None)
    _ = config.pluginmanager.register(guard, "agent-integrity-guard")
