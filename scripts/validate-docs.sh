#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' 'python3 is required for documentation validation' >&2
  exit 2
}

python3 - "$repo_root" <<'PY'
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

repo_root = Path(sys.argv[1]).resolve()


def repository_docs() -> list[Path]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            "*.md",
            "*.mdx",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        path
        for line in result.stdout.splitlines()
        if line and (path := repo_root / line).is_file()
    ]


def github_slug(heading: str) -> str:
    heading = re.sub(r"<[^>]*>", "", heading)
    heading = re.sub(r"[`*_~]", "", heading).strip().lower()
    heading = re.sub(r"[^\w\- ]", "", heading, flags=re.UNICODE)
    return re.sub(r" +", "-", heading)


def markdown_anchors(text: str) -> set[str]:
    anchors: set[str] = set()
    counts: dict[str, int] = {}
    for line in text.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not match:
            continue
        base = github_slug(match.group(1))
        duplicate = counts.get(base, 0)
        counts[base] = duplicate + 1
        anchors.add(base if duplicate == 0 else f"{base}-{duplicate}")
    return anchors


def prose_without_fences(text: str) -> str:
    lines: list[str] = []
    in_fence = False
    marker = ""
    for line in text.splitlines(keepends=True):
        fence = re.match(r"^\s*(```+|~~~+)", line)
        if fence:
            current = fence.group(1)[0]
            if not in_fence:
                in_fence = True
                marker = current
            elif current == marker:
                in_fence = False
            lines.append("\n")
        elif in_fence:
            lines.append("\n")
        else:
            lines.append(line)
    return "".join(lines)


docs = repository_docs()
texts = {path: path.read_text(encoding="utf-8") for path in docs}
anchors = {path: markdown_anchors(text) for path, text in texts.items()}
errors: list[str] = []
checked_links = 0
link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

for source, original_text in texts.items():
    text = prose_without_fences(original_text)
    for match in link_pattern.finditer(text):
        raw_target = match.group(1).strip()
        if raw_target.startswith("<") and ">" in raw_target:
            target = raw_target[1 : raw_target.index(">")]
        else:
            target = raw_target.split(maxsplit=1)[0]
        if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
            continue

        checked_links += 1
        path_text, separator, fragment = target.partition("#")
        destination = (
            source if not path_text else (source.parent / unquote(path_text)).resolve()
        )
        line = original_text.count("\n", 0, match.start()) + 1
        location = f"{source.relative_to(repo_root)}:{line}"

        if not destination.exists():
            errors.append(f"{location}: missing local link target: {target}")
            continue
        if separator and fragment and destination.suffix.lower() in {".md", ".mdx"}:
            if unquote(fragment) not in anchors.get(destination, set()):
                errors.append(f"{location}: missing heading anchor: {target}")

index = repo_root / "gitops/docs/README.md"
if not index.is_file():
    errors.append("gitops/docs/README.md: missing GitOps documentation index")
else:
    index_text = index.read_text(encoding="utf-8")
    docs_root = repo_root / "gitops/docs"
    for path in sorted(docs_root.rglob("*")):
        if path.suffix.lower() not in {".md", ".mdx", ".html"} or path == index:
            continue
        relative = path.relative_to(docs_root).as_posix()
        if relative.startswith("research/") or path.name.startswith("research-"):
            continue
        if relative not in index_text:
            errors.append(
                f"gitops/docs/README.md: active document is not cataloged: {relative}"
            )

for error in errors:
    print(error, file=sys.stderr)

if errors:
    print(
        f"documentation validation: FAIL ({len(errors)} errors; "
        f"{len(docs)} files, {checked_links} local links checked)",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"documentation validation: PASS "
    f"({len(docs)} files, {checked_links} local links checked)"
)
PY
