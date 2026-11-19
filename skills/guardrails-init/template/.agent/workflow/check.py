"""Reads a GitHub Actions workflow as data and prints what the guard refuses in it, one problem per line.

Usage (the workflow on stdin):
  python3 -I -S -B check.py token-problems
      Every workflow: a token that may write checks or statuses (write-all included), a permission value
      GitHub does not define, or YAML this check cannot read.
  python3 -I -S -B check.py changed-problems <path>
      A workflow a change adds or edits: any write permission, a job id or job name of a required check
      (guard, security, checks-<lang>, merge-approval) outside its own file, a job name computed by an
      expression, the name merge-approval, the guard workflow's triggers, or YAML this check cannot read.

Exit status 0 means the check ran: no output accepts the workflow, each line is a problem. Any other status
means it could not run, which the callers treat as a failure.

ci-guard (CI) and the owner's approval (bin/guardrails-lib.sh) run this same file. Both pass -B, so no
bytecode lands next to it. Its parser is PyYAML's scanner and parser, used for events only
(guardrails_pyyaml/): no constructor or resolver runs, so nothing in the document is ever built into an
object, and every scalar stays the string it spells, `on` included (a YAML 1.1 resolver would turn it into
true). Escapes, quoting, flow collections and block scalars are read the way YAML defines them. Forms where
parsers disagree or that hide one value behind another fail closed: duplicate keys (compared trimmed and
case-insensitively), anchors, aliases and merge keys (GitHub supports anchors and aliases since 2025, but
not merge keys; workflows here stay without them so every key reads in place), explicit tags, directives,
more than one document, keys that are not scalars, the characters YAML 1.1 and 1.2 read differently (NEL,
U+2028, U+2029, a byte order mark, a lone CR), deep nesting and large files.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Union

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from guardrails_pyyaml.error import MarkedYAMLError, YAMLError
from guardrails_pyyaml.events import (
    AliasEvent,
    DocumentEndEvent,
    DocumentStartEvent,
    Event,
    MappingEndEvent,
    MappingStartEvent,
    NodeEvent,
    ScalarEvent,
    SequenceEndEvent,
    SequenceStartEvent,
    StreamEndEvent,
    StreamStartEvent,
)
from guardrails_pyyaml.parser import Parser
from guardrails_pyyaml.reader import Reader
from guardrails_pyyaml.scanner import Scanner

YamlValue = Union[str, List["YamlValue"], Dict[str, "YamlValue"]]
YamlMapping = Dict[str, "YamlValue"]

MAX_BYTES = 256 * 1024
# PyYAML's scanner slows down quadratically with nesting depth; workflows need far less than this.
MAX_DEPTH = 32
WORKFLOW_KEYS = ("name", "run-name", "on", "permissions", "env", "defaults", "concurrency", "jobs")
PERMISSION_LEVELS = ("read", "write", "none")
CHECK_WRITE_SCOPES = ("checks", "statuses")
RESERVED_NAMES = ("guard", "security", "merge-approval")
AMBIGUOUS_CHARACTERS = {
    "﻿": "a byte order mark (U+FEFF)",
    "\x85": "a NEL line break (U+0085)",
    " ": "a line separator (U+2028)",
    " ": "a paragraph separator (U+2029)",
}
GUARD_WORKFLOW = ".github/workflows/agent-guard.yml"
GUARD_TRIGGER_PROBLEM = (
    "changes the guard trigger (it must stay pull_request_target and merge_group with checks_requested only)"
)


class UnreadableWorkflow(Exception):
    """The workflow is malformed, ambiguous or uses YAML this check does not accept."""


@dataclass(frozen=True)
class PermissionSet:
    """A `permissions` value and where it applies (the workflow or one job)."""

    where: str
    value: YamlValue


class EventReader(Reader, Scanner, Parser):
    """PyYAML's reader, scanner and parser over one string, yielding parse events only."""

    def __init__(self, text: str) -> None:
        Reader.__init__(self, text)
        Scanner.__init__(self)
        Parser.__init__(self)


def shown(text: str) -> str:
    """Quotes a string written by the workflow's author for a message line, short and without escapes."""
    quoted = json.dumps(text if len(text) <= 60 else text[:60] + "...", ensure_ascii=True)
    return quoted.replace("`", "\\u0060")


def line_of(event: Event) -> int:
    return int(event.start_mark.line) + 1


def normalized(text: str) -> str:
    return text.strip().lower()


def decoded(data: bytes) -> str:
    """The workflow as text: strict UTF-8, small, and without the characters YAML versions read differently."""
    if len(data) > MAX_BYTES:
        raise UnreadableWorkflow(f"is larger than {MAX_BYTES} bytes")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise UnreadableWorkflow(f"is not UTF-8 (byte {error.start})") from error
    for character, description in AMBIGUOUS_CHARACTERS.items():
        if character in text:
            raise UnreadableWorkflow(f"contains {description}, which YAML versions read differently")
    if re.search(r"\r(?!\n)", text):
        raise UnreadableWorkflow("contains a carriage return outside a CRLF line ending")
    return text


def checked_node_event(event: Event) -> NodeEvent:
    """Refuses aliases, anchors and explicit tags on a node."""
    if isinstance(event, AliasEvent):
        raise UnreadableWorkflow(f"uses a YAML alias (line {line_of(event)}); write the value in place")
    if not isinstance(event, NodeEvent):
        raise UnreadableWorkflow(f"has unexpected YAML structure (line {line_of(event)})")
    if event.anchor is not None:
        raise UnreadableWorkflow(f"uses a YAML anchor (line {line_of(event)}); write the value in place")
    tag = getattr(event, "tag", None)
    if tag is not None:
        raise UnreadableWorkflow(f"uses a YAML tag (line {line_of(event)}); write the plain value instead")
    return event


def read_key(events: EventReader, seen: Dict[str, int]) -> str:
    """Reads one mapping key: a scalar, not the merge key, not a duplicate of an earlier key."""
    event = checked_node_event(events.get_event())
    if not isinstance(event, ScalarEvent):
        raise UnreadableWorkflow(f"uses a key that is not a plain value (line {line_of(event)})")
    key = str(event.value)
    if key == "<<":
        raise UnreadableWorkflow(f"uses a YAML merge key (line {line_of(event)}); GitHub does not support it")
    earlier = seen.get(normalized(key))
    if earlier is not None:
        raise UnreadableWorkflow(f"defines the key {shown(key)} twice (lines {earlier} and {line_of(event)})")
    seen[normalized(key)] = line_of(event)
    return key


def read_value(events: EventReader, depth: int) -> YamlValue:
    """Reads one node into strings, lists and mappings."""
    event = checked_node_event(events.get_event())
    if isinstance(event, ScalarEvent):
        return str(event.value)
    if depth >= MAX_DEPTH:
        raise UnreadableWorkflow(f"nests deeper than {MAX_DEPTH} levels (line {line_of(event)})")
    if isinstance(event, SequenceStartEvent):
        items: List[YamlValue] = []
        while not events.check_event(SequenceEndEvent):
            items.append(read_value(events, depth + 1))
        events.get_event()
        return items
    if isinstance(event, MappingStartEvent):
        mapping: YamlMapping = {}
        seen: Dict[str, int] = {}
        while not events.check_event(MappingEndEvent):
            key = read_key(events, seen)
            mapping[key] = read_value(events, depth + 1)
        events.get_event()
        return mapping
    raise UnreadableWorkflow(f"has unexpected YAML structure (line {line_of(event)})")


def read_document(text: str) -> YamlValue:
    """The single YAML document of the text, as plain data."""
    events = EventReader(text)
    try:
        if not isinstance(events.get_event(), StreamStartEvent):
            raise UnreadableWorkflow("has unexpected YAML structure")
        start = events.get_event()
        if isinstance(start, StreamEndEvent):
            raise UnreadableWorkflow("holds no YAML document")
        if not isinstance(start, DocumentStartEvent):
            raise UnreadableWorkflow("has unexpected YAML structure")
        if start.version is not None or start.tags is not None:
            raise UnreadableWorkflow(f"uses a YAML directive (line {line_of(start)})")
        document = read_value(events, 0)
        if not isinstance(events.get_event(), DocumentEndEvent):
            raise UnreadableWorkflow("has unexpected YAML structure")
        end = events.get_event()
        if not isinstance(end, StreamEndEvent):
            raise UnreadableWorkflow(f"holds more than one YAML document (line {line_of(end)})")
        return document
    except MarkedYAMLError as error:
        mark = error.problem_mark or error.context_mark
        where = f" (line {int(mark.line) + 1})" if mark is not None else ""
        raise UnreadableWorkflow(f"is not valid YAML: {error.problem or error.context}{where}") from error
    except YAMLError as error:
        raise UnreadableWorkflow(f"is not valid YAML: {error}") from error


def lookup(mapping: YamlMapping, name: str) -> Optional[YamlValue]:
    """The value of a key, matched trimmed and case-insensitively (duplicates that way were refused)."""
    for key, value in mapping.items():
        if normalized(key) == name:
            return value
    return None


def read_workflow(data: bytes) -> YamlMapping:
    """The workflow's top-level mapping; only the keys GitHub defines, spelled exactly."""
    document = read_document(decoded(data))
    if not isinstance(document, dict):
        raise UnreadableWorkflow("is not a mapping of workflow keys")
    for key in document:
        if key not in WORKFLOW_KEYS:
            raise UnreadableWorkflow(f"has the top-level key {shown(key)}, which GitHub workflows do not define")
    return document


def jobs_of(workflow: YamlMapping) -> Dict[str, YamlMapping]:
    jobs = lookup(workflow, "jobs")
    if jobs is None:
        return {}
    if not isinstance(jobs, dict):
        raise UnreadableWorkflow("has `jobs` that is not a mapping of jobs")
    result: Dict[str, YamlMapping] = {}
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            raise UnreadableWorkflow(f"has the job {shown(job_id)}, which is not a mapping")
        result[job_id] = job
    return result


def permission_sets(workflow: YamlMapping) -> List[PermissionSet]:
    """Every `permissions` value of the workflow and its jobs."""
    sets: List[PermissionSet] = []
    top = lookup(workflow, "permissions")
    if top is not None:
        sets.append(PermissionSet("the workflow", top))
    for job_id, job in jobs_of(workflow).items():
        value = lookup(job, "permissions")
        if value is not None:
            sets.append(PermissionSet(f"job {shown(job_id)}", value))
    return sets


def permission_levels(permissions: PermissionSet) -> Dict[str, str]:
    """The level of each scope of a permissions mapping, normalized; unknown levels fail closed."""
    if not isinstance(permissions.value, dict):
        raise UnreadableWorkflow(f"has permissions in {permissions.where} that are neither a mapping nor a word")
    levels: Dict[str, str] = {}
    for scope, level in permissions.value.items():
        if not isinstance(level, str) or normalized(level) not in PERMISSION_LEVELS:
            raise UnreadableWorkflow(
                f"has the permission {shown(scope)} in {permissions.where} with a level GitHub does not define"
            )
        levels[normalized(scope)] = normalized(level)
    return levels


def whole_permission(permissions: PermissionSet) -> str:
    """read-all or write-all, normalized; any other word fails closed."""
    if not isinstance(permissions.value, str) or normalized(permissions.value) not in ("read-all", "write-all"):
        raise UnreadableWorkflow(f"has permissions in {permissions.where} that GitHub does not define")
    return normalized(permissions.value)


def token_problems(workflow: YamlMapping) -> List[str]:
    """Each place where the workflow's token may write checks or statuses."""
    problems: List[str] = []
    for permissions in permission_sets(workflow):
        if isinstance(permissions.value, str):
            if whole_permission(permissions) == "write-all":
                problems.append(
                    f"grants write-all in {permissions.where}, so its token can write checks and statuses,"
                    " which could fake a required check"
                )
            continue
        for scope, level in permission_levels(permissions).items():
            if scope in CHECK_WRITE_SCOPES and level == "write":
                problems.append(
                    f"lets its token write {scope} in {permissions.where}, which could fake a required check"
                )
    return problems


def write_problems(workflow: YamlMapping) -> List[str]:
    """Each write permission the workflow asks for: a workflow a change touches stays read-only."""
    problems: List[str] = []
    for permissions in permission_sets(workflow):
        if isinstance(permissions.value, str):
            if whole_permission(permissions) == "write-all":
                problems.append(
                    f"requests a write permission for its token (write-all in {permissions.where});"
                    " workflows changed by a PR stay read-only"
                )
            continue
        for scope, level in permission_levels(permissions).items():
            if level == "write":
                problems.append(
                    f"requests a write permission for its token ({scope} in {permissions.where});"
                    " workflows changed by a PR stay read-only"
                )
    return problems


def own_check_name(path: str) -> str:
    """The required check a kit workflow reports itself, or "" for any other workflow. The guard workflow may
    define `guard` only: on merge_group GitHub runs the PR's own copy of it, where a job named like another
    required check would report on the group commit."""
    name = path.rsplit("/", 1)[-1]
    if path == GUARD_WORKFLOW:
        return "guard"
    if name == "security.yml" or (name.startswith("checks-") and name.endswith(".yml")):
        return name[: -len(".yml")]
    return ""


def is_reserved(name: str) -> bool:
    return name in RESERVED_NAMES or name.startswith("checks-")


def name_problems(path: str, workflow: YamlMapping) -> List[str]:
    """Job ids and job names that a required check reports under, outside the check's own file."""
    problems: List[str] = []
    own = own_check_name(path)
    for job_id, job in jobs_of(workflow).items():
        names = [job_id]
        name = lookup(job, "name")
        if name is not None:
            if not isinstance(name, str):
                raise UnreadableWorkflow(f"has a name for job {shown(job_id)} that is not a single value")
            if "${{" in name:
                problems.append(f"computes the name of job {shown(job_id)} with an expression")
            names.append(name)
        for candidate in names:
            if is_reserved(normalized(candidate)) and normalized(candidate) != own:
                problems.append(f"defines a job or name {shown(candidate)}, which belongs to a required check")
    return problems


def scalars(value: YamlValue) -> List[str]:
    """Every key and scalar of a value, as interpreted."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [text for item in value for text in scalars(item)]
    return [text for key, item in value.items() for text in [key, *scalars(item)]]


def names_merge_approval(text: str, workflow: YamlMapping) -> bool:
    return any("merge-approval" in candidate.lower() for candidate in [text, *scalars(workflow)])


def is_word_list(value: Optional[YamlValue], pattern: str) -> bool:
    return isinstance(value, list) and len(value) > 0 and all(
        isinstance(item, str) and re.fullmatch(pattern, item) is not None for item in value
    )


def guard_trigger_problems(workflow: YamlMapping) -> List[str]:
    """The guard workflow's `on` must stay exactly pull_request_target (judged from the default branch) and
    merge_group with checks_requested only (judged with the default branch's guard too). A PR may not add a
    trigger (a push or pull_request run would execute the workflow as the PR wrote it, for every PR) nor remove
    one (without merge_group a merge queue waits forever, without pull_request_target no PR is judged)."""
    on = workflow.get("on")
    if not isinstance(on, dict) or sorted(on) != ["merge_group", "pull_request_target"]:
        return [GUARD_TRIGGER_PROBLEM]
    target = on["pull_request_target"]
    group = on["merge_group"]
    target_ok = isinstance(target, dict) and list(target) == ["types"] and is_word_list(target["types"], "[a-z_]+")
    group_ok = isinstance(group, dict) and list(group) == ["types"] and group["types"] == ["checks_requested"]
    return [] if target_ok and group_ok else [GUARD_TRIGGER_PROBLEM]


def changed_problems(path: str, data: bytes) -> List[str]:
    workflow = read_workflow(data)
    problems = write_problems(workflow) + name_problems(path, workflow)
    if path == GUARD_WORKFLOW:
        # Its comments explain merge-approval; it cannot post statuses (token_problems checks every workflow).
        problems += guard_trigger_problems(workflow)
    elif names_merge_approval(data.decode("utf-8"), workflow):
        problems.append("names merge-approval")
    return problems


def printable(line: str) -> str:
    """Drops what could redraw the reader's terminal or break the guard summary's Markdown fence."""
    return re.sub(r"[\x00-\x1f\x7f-\x9f`  ﻿]", "?", line)


def main(arguments: List[str]) -> int:
    if sys.version_info < (3, 8):
        print("check.py needs Python 3.8 or newer", file=sys.stderr)
        return 3
    token = arguments == ["token-problems"]
    changed = len(arguments) == 2 and arguments[0] == "changed-problems"
    if not token and not changed:
        print("usage: check.py token-problems | check.py changed-problems <path>  (workflow on stdin)", file=sys.stderr)
        return 2
    data = sys.stdin.buffer.read()
    try:
        problems = token_problems(read_workflow(data)) if token else changed_problems(arguments[1], data)
    except UnreadableWorkflow as error:
        problems = [f"{error}; the guard reads workflows as plain YAML only"]
    for problem in problems:
        print(printable(problem))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
