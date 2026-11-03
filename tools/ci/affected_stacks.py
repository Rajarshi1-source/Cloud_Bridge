#!/usr/bin/env python3
"""Map changed files to the live stacks CI plans (directly, or through the modules they call).

    python3 tools/ci/affected_stacks.py --base origin/main [--ordered]

Only the stacks in PIPELINE go through plan and apply. The rest are affected but not planned, and the
PR comment says so: *-dev cells are ephemeral (ephemeral-up.yml), 00-ci-identity is bootstrapped by a
human, and 20-origin-tls's state holds the origin private key, which plan identities can't read.
"""
import argparse
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
PIPELINE = {"aws-budget/10-foundation", "gcp-budget/10-foundation", "global/30-traffic"}
LAYERS = {"10-foundation": "foundation", "20-bootstrap": "bootstrap", "30-traffic": "traffic"}
ENVIRONMENTS = {"global/30-traffic": "traffic-prod"}
EXTRA_INPUTS = {"global/30-traffic": ["gitops/global/values.yaml"], "global/20-origin-tls": ["gitops/global/values.yaml"]}
SOURCE = re.compile(r'source\s*=\s*"(\.\.?/[^"]+)"')


def changed(base: str, root: pathlib.Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "diff", "--name-only", f"{base}...HEAD"], capture_output=True, text=True, check=True
    )
    return out.stdout.splitlines()


def module_closure(stack: pathlib.Path) -> set[pathlib.Path]:
    seen: set[pathlib.Path] = set()
    todo = [stack]
    while todo:
        directory = todo.pop()
        for tf in directory.glob("*.tf"):
            for rel in SOURCE.findall(tf.read_text(encoding="utf-8")):
                module = (directory / rel).resolve()
                if module not in seen and module.is_dir():
                    seen.add(module)
                    todo.append(module)
    return seen


def stacks(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted(p for p in (root / "infra/live").glob("*/*") if p.is_dir() and any(p.glob("*.tf")))


def describe(stack: pathlib.Path, root: pathlib.Path) -> dict:
    name = f"{stack.parent.name}/{stack.name}"
    cell = stack.parent.name
    return {
        "path": stack.relative_to(root).as_posix(),
        "name": name,
        "cloud": "global" if cell == "global" else cell.split("-")[0],
        "env": ENVIRONMENTS.get(name, cell),
        "layer": LAYERS.get(stack.name, stack.name),
    }


def affected(files: list[str], root: pathlib.Path) -> dict:
    resolved = [(root / f).resolve() for f in files]
    planned, skipped = [], []
    for stack in stacks(root):
        info = describe(stack, root)
        deps = module_closure(stack) | {stack.resolve()}
        hit = any(d in f.parents for f in resolved for d in deps)
        hit = hit or any((root / x).resolve() in resolved for x in EXTRA_INPUTS.get(info["name"], []))
        if hit:
            (planned if info["name"] in PIPELINE else skipped).append(info)
    # The smaller cell first (gcp before aws), like the release ring.
    planned.sort(key=lambda s: (list(LAYERS.values()).index(s["layer"]), 0 if s["cloud"] == "gcp" else 1))
    return {
        "stacks": planned,
        "not_planned": [s["path"] for s in skipped],
        "layers": {layer: [s for s in planned if s["layer"] == layer] for layer in LAYERS.values()},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    args = parser.parse_args()
    print(json.dumps(affected(changed(args.base, ROOT), ROOT), indent=2))


if __name__ == "__main__":
    main()
