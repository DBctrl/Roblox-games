#!/usr/bin/env python3
"""QA-7 static twin of the EconomyConfig.spec "BOSSES ids and worlds match MapLayout.BOSS_IDS" test.

Owned by qa. Pure standard library, no Studio needed. Run from the repo root:

    python3 -I tests/static/check_boss_ids.py

Parses `{ id = "...", ..., world = N, ... }` rows in src/shared/Gameplay/EconomyConfig.luau and the
`MapLayout.BOSS_IDS` table in src/shared/World/MapLayout.luau, then checks that every boss has the same id, world
and stage-row order in both. A mismatch means the boss can never be fought (BossService compares worlds, and
ZoneService.isNearBoss finds the stage through MapLayout).
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ECONOMY = os.path.join(ROOT, "src", "shared", "Gameplay", "EconomyConfig.luau")
LAYOUT = os.path.join(ROOT, "src", "shared", "World", "MapLayout.luau")


def strip_comments(text: str) -> str:
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def economy_bosses(text: str) -> dict[int, list[str]]:
    out: dict[int, list[str]] = {}
    for row in re.finditer(r"\{[^{}]*\bid\s*=\s*\"(\w+)\"[^{}]*\bmpNeed\s*=[^{}]*\}", text):
        world = re.search(r"\bworld\s*=\s*(\d+)", row.group(0))
        if world is None:
            raise SystemExit(f"FAIL boss {row.group(1)} has no `world` field")
        out.setdefault(int(world.group(1)), []).append(row.group(1))
    return out


def layout_bosses(text: str) -> dict[int, list[str]]:
    m = re.search(r"MapLayout\.BOSS_IDS\s*=\s*table\.freeze\(\{(.*?)\n\}\)", text, re.S)
    if m is None:
        raise SystemExit("FAIL MapLayout.BOSS_IDS not found")
    out: dict[int, list[str]] = {}
    for world in re.finditer(r"\[(\d+)\]\s*=\s*table\.freeze\(\{(.*?)\}\)", m.group(1), re.S):
        out[int(world.group(1))] = re.findall(r"\"(\w+)\"", world.group(2))
    return out


def main() -> int:
    with open(ECONOMY, encoding="utf-8") as f:
        econ = economy_bosses(strip_comments(f.read()))
    with open(LAYOUT, encoding="utf-8") as f:
        layout = layout_bosses(strip_comments(f.read()))
    fails = 0
    for world in sorted(set(econ) | set(layout)):
        a, b = econ.get(world, []), layout.get(world, [])
        if a == b:
            print(f"  PASS    world {world}: {len(a)} bosses match ({', '.join(a)})")
        else:
            fails += 1
            print(f"  FAIL    world {world}: EconomyConfig {a} != MapLayout {b}")
    total = sum(len(v) for v in econ.values())
    print(f"\nBOSS ID RESULT: {fails} fail, {total} EconomyConfig bosses")
    return 1 if fails or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
