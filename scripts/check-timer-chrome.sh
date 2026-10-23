#!/usr/bin/env bash
# Fail when a SwiftUI TimelineView (or Timer.publish schedule) wraps Liquid Glass /
# large Button chrome — the jetsam class that bites long nursing / sleep sessions.
#
# Digit-only TimelineViews (Text / *Digits / *Clock helpers) must pass.
# Escape hatch: put `timer-chrome-ok: <reason>` on the TimelineView line or the
# two lines above it (or list a path:line in scripts/timer-chrome-allowlist.txt).
#
# Usage:
#   ./scripts/check-timer-chrome.sh              # scan apps/ + packages/
#   ./scripts/check-timer-chrome.sh path.swift   # scan specific files
#   ./scripts/check-timer-chrome.sh --self-test  # fixture assertions
#
# Wire-up: GitHub Action `.github/workflows/timer-chrome.yml`, optional Xcode
# pre-build phase (see apps/README.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

exec python3 - "$ROOT" "$@" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1])
ARGS = sys.argv[2:]

# Tokens that must not appear inside a TimelineView schedule body (or as a
# trailing modifier on the TimelineView itself). ContinuousCornerCard embeds
# .benitoGlass — treat it as chrome.
FORBIDDEN_BODY = re.compile(
    r"""(?x)
    \.glassEffect\b
    | \bbenitoGlass(?:Capsule|Chrome)?\b
    | \bbenitoFloatingCapsule(?:Chrome)?\b
    | \bbenitoSelectable(?:Capsule|Card)?\b
    | \bbenitoNavigationBarGlass\b
    | \bPrimaryLogButton\b
    | \bContinuousCornerCard\b
    | \bThumbActionBar\b
    | \bRunningTimerBar\b
    | \bCircle\s*\(
    | \bButton\s*[\({]
    """
)

# Glass applied to the TimelineView via trailing modifiers (sibling of body).
FORBIDDEN_TRAIL = re.compile(
    r"""(?x)
    \.glassEffect\b
    | \.benitoGlass(?:Capsule|Chrome)?\b
    | \.benitoFloatingCapsule(?:Chrome)?\b
    | \.benitoSelectable(?:Capsule|Card)?\b
    | \.benitoNavigationBarGlass\b
    """
)

TIMELINE_START = re.compile(r"\bTimelineView\s*(?:<[^>]*>)?\s*\(")
TIMER_PUBLISH = re.compile(r"\bTimer\s*\.\s*publish\s*\(")
ALLOW_MARK = re.compile(r"timer-chrome-ok\b", re.I)
# Strip // and /* */ comments for scanning (keep newlines for line numbers).
COMMENT_LINE = re.compile(r"//.*?$", re.M)
COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.S)
STRING_LIT = re.compile(
    r'"""[\s\S]*?"""|#"(?:\\.|[^"\\])*"|"((?:\\.|[^"\\])*)"'
)


def strip_noise(src: str) -> str:
    """Replace comments/strings with spaces (preserve length / newlines)."""

    def blank(m: re.Match[str]) -> str:
        return "".join("\n" if ch == "\n" else " " for ch in m.group(0))

    out = COMMENT_BLOCK.sub(blank, src)
    out = COMMENT_LINE.sub(blank, out)
    out = STRING_LIT.sub(blank, out)
    return out


def line_of(src: str, index: int) -> int:
    return src.count("\n", 0, index) + 1


def brace_match(src: str, open_idx: int) -> int | None:
    """Return index of matching '}' for '{' at open_idx, or None."""
    if open_idx >= len(src) or src[open_idx] != "{":
        return None
    depth = 0
    i = open_idx
    while i < len(src):
        ch = src[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def find_body_open(src: str, after_paren: int) -> int | None:
    """After TimelineView(, skip balanced (...) then find trailing `{`."""
    # after_paren points at '(' of TimelineView(
    close = match_parens(src, after_paren)
    if close is None:
        return None
    i = close + 1
    while i < len(src) and src[i] in " \t\r\n":
        i += 1
    # optional trailing closure label bits already consumed; expect `{`
    if i < len(src) and src[i] == "{":
        return i
    # TimelineView(...) { context in ... } — sometimes newline then {
    while i < len(src) and src[i] in " \t\r\n":
        i += 1
    return i if i < len(src) and src[i] == "{" else None


def match_parens(src: str, open_idx: int) -> int | None:
    if open_idx >= len(src) or src[open_idx] != "(":
        return None
    depth = 0
    i = open_idx
    while i < len(src):
        ch = src[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        elif ch == "{":
            # rare: default arg closures inside (); still count braces? skip string-stripped
            end = brace_match(src, i)
            if end is None:
                return None
            i = end
        i += 1
    return None


def trail_slice(src: str, after_body: int) -> str:
    """Only modifiers chained directly onto the TimelineView (`}.benitoGlass()`).

    Stops before a sibling `}` / `else` / next statement so outer-VStack glass
    (digits tick inside, chrome outside) is not a false positive.
    """
    i = after_body + 1
    while i < len(src) and src[i] in " \t\r\n":
        i += 1
    if i >= len(src) or src[i] != ".":
        return ""
    start = i
    while i < len(src) and src[i] == ".":
        i += 1
        while i < len(src) and (src[i].isalnum() or src[i] == "_"):
            i += 1
        while i < len(src) and src[i] in " \t\r\n":
            i += 1
        if i < len(src) and src[i] == "(":
            close = match_parens(src, i)
            if close is None:
                break
            i = close + 1
        elif i < len(src) and src[i] == "{":
            close = brace_match(src, i)
            if close is None:
                break
            i = close + 1
        while i < len(src) and src[i] in " \t\r\n":
            i += 1
    return src[start:i]


def allow_near(raw: str, start_idx: int) -> bool:
    line_no = line_of(raw, start_idx)
    lines = raw.splitlines()
    # Check this line and two above for timer-chrome-ok (usually in a comment).
    for ln in range(max(1, line_no - 2), line_no + 1):
        if ALLOW_MARK.search(lines[ln - 1]):
            return True
    return False


def load_allowlist(path: Path) -> set[tuple[str, int]]:
    out: set[tuple[str, int]] = set()
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if ":" not in line:
            continue
        rel, ln = line.rsplit(":", 1)
        if ln.isdigit():
            out.add((rel.strip().replace("\\", "/"), int(ln)))
    return out


def scan_file(path: Path, rel: str, allowlist: set[tuple[str, int]]) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    src = strip_noise(raw)
    findings: list[str] = []

    for m in TIMELINE_START.finditer(src):
        paren = m.end() - 1  # '('
        if src[paren] != "(":
            # TimelineView without immediate ( — skip
            continue
        body_open = find_body_open(src, paren)
        if body_open is None:
            continue
        body_close = brace_match(src, body_open)
        if body_close is None:
            continue
        body = src[body_open + 1 : body_close]
        ln = line_of(raw, m.start())
        if allow_near(raw, m.start()) or (rel, ln) in allowlist:
            continue

        hits = sorted({h.group(0).strip() for h in FORBIDDEN_BODY.finditer(body)})
        trail = trail_slice(src, body_close)
        trail_hits = sorted({h.group(0).strip() for h in FORBIDDEN_TRAIL.finditer(trail)})

        if hits or trail_hits:
            parts = []
            if hits:
                parts.append("body: " + ", ".join(hits))
            if trail_hits:
                parts.append("trailing: " + ", ".join(trail_hits))
            findings.append(
                f"{rel}:{ln}: TimelineView wraps heavy chrome ({'; '.join(parts)}). "
                f"Keep digits-only inside the schedule; move glass/Button/Circle outside "
                f"(or add `timer-chrome-ok: <reason>`)."
            )

    # Timer.publish is not used today; still flag obvious same-file chrome coupling
    # when a publish schedule appears (comment-only mentions are stripped).
    for m in TIMER_PUBLISH.finditer(src):
        ln = line_of(raw, m.start())
        if allow_near(raw, m.start()) or (rel, ln) in allowlist:
            continue
        # Look ahead ~80 lines for chrome tokens in the same stripped source window.
        window = src[m.start() : m.start() + 3500]
        hits = sorted({h.group(0).strip() for h in FORBIDDEN_BODY.finditer(window)})
        if hits:
            findings.append(
                f"{rel}:{ln}: Timer.publish near heavy chrome ({', '.join(hits)}). "
                f"Prefer digit-only TimelineView ticks; keep glass outside the 1Hz path "
                f"(or add `timer-chrome-ok: <reason>`)."
            )

    return findings


def iter_swift(roots: list[Path]) -> list[Path]:
    skip_parts = {".build", ".derivedData", "checkouts", ".git", "Pods"}
    files: list[Path] = []
    for root in roots:
        if root.is_file() and root.suffix == ".swift":
            files.append(root)
            continue
        if not root.is_dir():
            continue
        for p in root.rglob("*.swift"):
            if any(part in skip_parts for part in p.parts):
                continue
            files.append(p)
    return sorted(files)


def self_test() -> int:
    import tempfile

    bad = """
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button("Save") { }
            Text("\\(context.date)")
        }
    }
    """
    bad_glass = """
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("00:01")
        }
        .benitoGlass()
    }
    """
    good = """
    var body: some View {
        TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
            Text(PrototypeFormatters.timerClock(timer.elapsed(at: context.date)))
                .monospacedDigit()
        }
        .benitoGlass() // glass on sibling? wait — trailing on TimelineView is bad
    }
    """
    # Note: good fixture above intentionally has trailing glass — should FAIL.
    good_digits = """
    private var clock: some View {
        TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
            clockText(timer.elapsed(at: context.date))
        }
    }
    private func clockText(_ t: TimeInterval) -> some View {
        Text("ok").monospacedDigit()
    }
    """
    allowed = """
    // timer-chrome-ok: fixture escape
    TimelineView(.periodic(from: .now, by: 1)) { _ in
        Circle().fill(.red)
    }
    """
    circle_bad = """
    TimelineView(.periodic(from: .now, by: 1)) { _ in
        Circle()
            .stroke(Color.red)
        Text("1")
    }
    """

    cases = [
        ("bad_button", bad, True),
        ("bad_trail_glass", bad_glass, True),
        ("good_digits", good_digits, False),
        ("allowed", allowed, False),
        ("circle_bad", circle_bad, True),
    ]
    failed = 0
    with tempfile.TemporaryDirectory() as td:
        tdir = Path(td)
        for name, src, expect_fail in cases:
            p = tdir / f"{name}.swift"
            p.write_text(src, encoding="utf-8")
            findings = scan_file(p, name + ".swift", set())
            got_fail = bool(findings)
            if got_fail != expect_fail:
                print(f"SELF-TEST FAIL {name}: expect_fail={expect_fail} got={findings}")
                failed += 1
            else:
                print(f"SELF-TEST OK   {name} (fail={got_fail})")
    return 1 if failed else 0


def main() -> int:
    if ARGS and ARGS[0] == "--self-test":
        return self_test()

    allowlist = load_allowlist(ROOT / "scripts" / "timer-chrome-allowlist.txt")
    if ARGS:
        roots = [Path(a) if Path(a).is_absolute() else ROOT / a for a in ARGS]
    else:
        roots = [ROOT / "apps", ROOT / "packages"]

    findings: list[str] = []
    for path in iter_swift(roots):
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        findings.extend(scan_file(path, rel, allowlist))

    if findings:
        print("check-timer-chrome: FAIL — TimelineView/Timer must not wrap heavy chrome\n")
        for f in findings:
            print(f"  {f}")
        print(
            "\nKeep 1Hz/periodic schedules on digit Texts only; glass, Circle, and "
            "large Buttons stay outside. Escape: `timer-chrome-ok: reason` comment "
            "or scripts/timer-chrome-allowlist.txt"
        )
        return 1

    print("check-timer-chrome: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
