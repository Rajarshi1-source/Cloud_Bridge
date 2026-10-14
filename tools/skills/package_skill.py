"""Validate a CloudBridge skill directory and rebuild its .skill package.

The directory .claude/skills/<name>/ is the only editable source; <name>.skill is a build
artifact next to it. Usage:

    python tools/skills/package_skill.py .claude/skills/cloudbridge-cell-services [...more dirs]
    python tools/skills/package_skill.py --all            # every .claude/skills/*/ with a SKILL.md
    python tools/skills/package_skill.py --check ...      # validate only, don't write the zip
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import yaml

SKILLS_ROOT = Path(__file__).resolve().parents[2] / ".claude" / "skills"
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
FENCE_RE = re.compile(r"^```(\w+)[^\n]*\n(.*?)^```", re.M | re.S)
FIXED_DATE = (2026, 1, 1, 0, 0, 0)  # deterministic zips: same content → same bytes


def frontmatter(text: str) -> dict:
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        raise ValueError("SKILL.md has no YAML frontmatter")
    return yaml.safe_load(m.group(1))


def check_blocks(path: Path) -> list[str]:
    """Parse the fenced blocks a parser can check; Helm templates and Jinja are skipped."""
    errors = []
    for lang, body in FENCE_RE.findall(path.read_text(encoding="utf-8")):
        lang = lang.lower()
        try:
            if lang in ("yaml", "yml"):
                if "{{" in body or "{%" in body:
                    continue
                list(yaml.safe_load_all(body))
            elif lang == "json":
                # Skills label JSON blocks with a leading "// path" line; the real file has none.
                json.loads(re.sub(r"\A(\s*//[^\n]*\n)+", "", body))
            elif lang == "xml":
                ElementTree.fromstring(body)
        except Exception as e:  # noqa: BLE001 — report every parser's error the same way
            errors.append(f"{path.name}: {lang} block does not parse: {e}".splitlines()[0])
    return errors


def validate(skill_dir: Path) -> list[str]:
    errors = []
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return [f"{skill_dir}: missing SKILL.md"]
    meta = frontmatter(skill_md.read_text(encoding="utf-8"))
    name, desc = meta.get("name", ""), meta.get("description", "")
    if name != skill_dir.name:
        errors.append(f"name '{name}' != directory '{skill_dir.name}'")
    if not NAME_RE.match(name) or len(name) > 64:
        errors.append(f"name '{name}' must be kebab-case and under 64 chars")
    if not desc or len(desc) > 1024:
        errors.append(f"description length {len(desc)} (must be 1..1024)")
    if "<" in desc or ">" in desc:
        errors.append("description contains angle brackets")
    for md in [skill_md, *sorted((skill_dir / "references").glob("*.md"))]:
        errors.extend(check_blocks(md))
    return errors


def package(skill_dir: Path) -> Path:
    out = skill_dir.parent / f"{skill_dir.name}.skill"
    files = [skill_dir / "SKILL.md", *sorted((skill_dir / "references").glob("*"))]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            info = zipfile.ZipInfo(f"{skill_dir.name}/{f.relative_to(skill_dir).as_posix()}", FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, f.read_bytes())
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="*", type=Path)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--check", action="store_true", help="validate only")
    args = ap.parse_args()
    dirs = sorted(p.parent for p in SKILLS_ROOT.glob("*/SKILL.md")) if args.all else args.dirs
    if not dirs:
        ap.error("give skill directories or --all")

    failed = False
    for d in dirs:
        d = d.resolve()
        errors = validate(d)
        if errors:
            failed = True
            print(f"FAIL {d.name}")
            for e in errors:
                print(f"  - {e}")
            continue
        if args.check:
            print(f"ok   {d.name}")
        else:
            out = package(d)
            with zipfile.ZipFile(out) as zf:
                print(f"ok   {d.name} -> {out.name} ({len(zf.namelist())} files)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
