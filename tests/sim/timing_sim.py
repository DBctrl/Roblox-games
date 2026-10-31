#!/usr/bin/env python3
"""T-024 timing sim: reproduces GDD 4.7 (free player, life 1, no Robux) from the numbers in docs/gdd.md.

Owned by qa. Pure standard library. Run from the repo (or worktree) root:

    python3 -I tests/sim/timing_sim.py            # prints the report table
    python3 -I tests/sim/timing_sim.py --markdown # same, as markdown for docs/qa/

Every balance number is parsed from docs/gdd.md tables (4.2 tools, 4.3 pods, 4.4 bosses, 5 Basic Egg,
7 ranks) and the 4.5 / architecture 1c formulas, so a GDD retune changes the sim without code edits.
Behaviour assumptions (walk times, purchase order) are the constants below and are listed in the report.

Model (one free player, PvE, time step 0.05 s):
- Tapping starts after the 10 s spawn pan (GDD 4.7 row 0:00-0:10) at TAPS_PER_SEC, never above the 12/s cap.
  Taps continue while walking and while a 3 s fight runs (MP is a threshold, not spent).
- Fights: strongest boss in World 1 with MP >= need; 4 s cycle (3 s fight + 1 s), coins paid at the end of
  the cycle. First approach to a new boss costs WALK_BOSS seconds.
- Purchases follow the 4.7 order. Each costs WALK_SHOP seconds of walking (no fights meanwhile).
- Pods: scenario "pod+boss" counts pod MP/s all the time once bought (pod within boss range, the upper
  bound); scenario "boss-only" never counts pod MP/s, because the player is always at a boss stage.
- Basic Egg: one hatch, its expected pet bonus (EV of the odds table) is added to PetMult.
- Rank 3 unlocks free Auto-Tap (3 taps/s, GDD 4.6); total accepted taps stay <= 12/s.
- First rebirth = the moment coins >= rebirthCost(1).
Targets: two-sided bands pass within BAND_TOLERANCE (15 s, D-052) of either edge; "< X" caps are strict.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GDD = os.path.join(ROOT, "docs", "gdd.md")

# Behaviour assumptions (not in the GDD; stated in the report) -----------------------------------------
SPAWN_PAN = 10.0  # GDD 4.7: 0:00-0:10 spawn and camera pan, tapping starts after
WALK_BOSS = 3.0  # GDD 9: "walk ~3 s" to Sid; reused for every new boss
WALK_SHOP = 5.0  # assumed walk to the Tool Stand / pod / egg stand and back
FIGHT_CYCLE = 4.0  # GDD 4 assumptions: 3 s mog-off + 1 s
TAP_CAP = 12.0  # GDD 4.6 / architecture TAP_CAP_PER_SEC
AUTO_TAP_RATE = 3.0  # GDD 4.6 free Auto-Tap
AUTO_TAP_RANK = 3
DT = 0.05
LIMIT = 40 * 60.0
# D-052: a two-sided band (lo > 0) passes within this many seconds outside either edge, because the sim's
# modelling precision (walk times, 0.05 s step, EV pets) is coarser than a few seconds. "< X" caps stay strict.
BAND_TOLERANCE = 15.0

# GDD targets (4.7 Check column, 9) in seconds: (label, event key, max seconds or (min, max))
# (label, event, (lo, hi) seconds, taps/s the target applies to; None = every rate)
TARGETS = [
    ("First boss win < 60 s", "first_win", (0, 60), None),
    ("First upgrade (Hair Gel) < 2 min", "tool_2", (0, 120), None),
    ("First idle station (Ring Light Pod) < 3 min", "pod_1", (0, 180), None),
    ("First rank-up (Rank 2) < 5 min", "rank_2", (0, 300), None),
    ("First rebirth in the 4.7 check column ~10-15 min", "rebirth_1", (600, 900), None),
    # GDD rev 2 (D-033, 4.7): first-rebirth band 10:30-12:00 at 5 taps/s, 12:30-15:00 at 3 taps/s
    ("First rebirth in the rev 2 band 10:30-12:00 (5 taps/s)", "rebirth_1", (630, 720), {5}),
    ("First rebirth in the rev 2 band 12:30-15:00 (3 taps/s)", "rebirth_1", (750, 900), {3}),
]

# GDD 4.7 table times, for the "GDD says" column
GDD_TIMES = {  # rev 2 (D-033): the 5 taps/s "pod counts" column of GDD 4.7
    "first_win": 36,
    "tool_2": 56,
    "boss_Bedhead Benny": 102,
    "pod_1": 126,
    "tool_3": 183,
    "rank_2": 168,
    "boss_Sweatband Sal": 220,
    "egg_basic": 236,
    "tool_4": 330,
    "boss_Captain Cardio": 432,
    "rank_3": 480,
    "rebirth_1": 641,
}


def num(cell: str) -> float:
    cell = cell.strip().replace(",", "").replace("+", "").replace("%", "")
    if cell.lower() == "free":
        return 0.0
    return float(cell)


def table_after(text: str, heading: str) -> list[list[str]]:
    """Rows (cells) of the first markdown table after the heading line that starts with `heading`."""
    lines = text.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.startswith(heading))
    rows: list[list[str]] = []
    started = False
    for ln in lines[start + 1 :]:
        if ln.startswith("|"):
            started = True
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        elif started:
            break
    return rows[1:]  # drop header


def load_gdd() -> dict:
    with open(GDD, encoding="utf-8") as f:
        text = f.read()
    tools = [
        {"name": r[1], "power": num(r[2]), "cost": num(r[3]), "world": int(num(r[4]))}
        for r in table_after(text, "### 4.2 Tools")
    ]
    pods = [{"name": r[1], "rate": num(r[2]), "cost": num(r[3])} for r in table_after(text, "### 4.3 Glow Pods")]
    bosses = []
    world = 1
    for r in table_after(text, "### 4.4 Bosses"):
        m = re.match(r"(\d)", r[0])
        if m:
            world = int(m.group(1))
        name = re.sub(r"\s*\(.*\)$", "", r[1])
        bosses.append({"world": world, "name": name, "need": num(r[2]), "coins": num(r[3])})
    ranks = [{"rank": int(r[0]), "name": r[1], "lifetime": num(r[2])} for r in table_after(text, "## 7. Rank")]
    # Basic Egg: first rows of the section 5 table until the next egg name in bold
    egg_rows = table_after(text, "## 5. Eggs and pets")
    basic = []
    for i, r in enumerate(egg_rows):
        if i > 0 and r[0].startswith("**"):
            break
        basic.append((num(r[3]), num(r[4]) / 100.0))
    m = re.search(r"\*\*Basic Egg\*\* \(W1, ([\d,]+) coins\)", text)
    basic_price = num(m.group(1)) if m else 500.0
    m = re.search(r"\*\*Cost:\*\* `([\d,]+) x 3\^\(n-1\)`", text)
    rebirth_base = num(m.group(1)) if m else 15000.0
    return {
        "tools": tools,
        "pods": pods,
        "bosses": bosses,
        "ranks": ranks,
        "basic_ev": sum(b * p for b, p in basic),
        "basic_odds_sum": sum(p for _, p in basic),
        "basic_price": basic_price,
        "rebirth_cost_1": rebirth_base,
    }


def load_eggs() -> list[dict]:
    """Every egg in the GDD 5 table: id, world, price (coins, or None for Robux), pets with weight per 10,000."""
    with open(GDD, encoding="utf-8") as f:
        text = f.read()
    eggs: list[dict] = []
    for r in table_after(text, "## 5. Eggs and pets"):
        m = re.match(r"\*\*(.+?)\*\* \(W(\d), ([^)]*)\)", r[0])
        if m:
            coins = re.match(r"([\d,]+) coins", m.group(3))
            eggs.append(
                {
                    "id": m.group(1).replace(" ", ""),
                    "world": int(m.group(2)),
                    "price": num(coins.group(1)) if coins else None,
                    "pets": [],
                }
            )
        eggs[-1]["pets"].append(
            {"name": r[1], "rarity": r[2], "bonus": num(r[3]), "weight": int(round(num(r[4]) * 100))}
        )
    return eggs


def luau_fixture(g: dict) -> str:
    """Luau source for tests/shared/Fixtures/GddTables.luau (regenerate after a GDD retune)."""
    out = [
        "--!strict",
        "-- GENERATED by `python3 -I tests/sim/timing_sim.py --luau-fixture` from docs/gdd.md, then stylua.",
        "-- Owned by qa. The tables-match-GDD test compares EconomyConfig against these values.",
        "",
        "local GddTables = {}",
        "",
        "GddTables.TOOLS = {",
    ]
    for t in g["tools"]:
        out.append(
            f'\t{{ name = "{t["name"]}", power = {t["power"]:g}, cost = {t["cost"]:.0f}, world = {t["world"]} }},'
        )
    out += ["}", "", "GddTables.PODS = {"]
    for p in g["pods"]:
        out.append(f'\t{{ name = "{p["name"]}", rate = {p["rate"]:g}, cost = {p["cost"]:.0f} }},')
    out += ["}", "", "GddTables.BOSSES = {"]
    for b in g["bosses"]:
        out.append(
            f'\t{{ name = "{b["name"]}", world = {b["world"]}, need = {b["need"]:.0f}, coins = {b["coins"]:.0f} }},'
        )
    out += ["}", "", "GddTables.RANKS = {"]
    for r in g["ranks"]:
        out.append(f'\t{{ rank = {r["rank"]}, name = "{r["name"]}", lifetime = {r["lifetime"]:.0f} }},')
    out += ["}", "", "GddTables.EGGS = {"]
    for e in load_eggs():
        price = "nil" if e["price"] is None else f'{e["price"]:.0f}'
        out.append(f'\t{{ id = "{e["id"]}", world = {e["world"]}, price = {price}, pets = {{')
        for p in e["pets"]:
            out.append(
                f'\t\t{{ name = "{p["name"]}", rarity = "{p["rarity"]}", bonus = {p["bonus"]:g}, '
                f'weight = {p["weight"]} }},'
            )
        out.append("\t} },")
    out += ["}", "", f'GddTables.REBIRTH_BASE = {g["rebirth_cost_1"]:.0f}', "", "return GddTables", ""]
    return "\n".join(out)


def simulate(g: dict, taps_per_sec: float, pod_counts: bool, plan: list[str]) -> dict[str, float]:
    t = 0.0
    mp = lifetime = coins = 0.0
    tool = 1
    pod_rate = 0.0
    pet_bonus = 0.0
    rank = 1
    events: dict[str, float] = {}
    queue = list(plan)
    busy_until = 0.0
    fight_end = None
    fight_boss = None
    last_boss = None
    w1 = [b for b in g["bosses"] if b["world"] == 1]

    def cost_of(item: str) -> float:
        kind, idx = item.split("_")
        if kind == "tool":
            return g["tools"][int(idx) - 1]["cost"]
        if kind == "pod":
            return g["pods"][int(idx) - 1]["cost"]
        return g["basic_price"]

    while t < LIMIT:
        m = 1.0 + pet_bonus  # life 1: RebirthMult 1, no paid terms
        manual = taps_per_sec if t >= SPAWN_PAN else 0.0
        auto = AUTO_TAP_RATE if rank >= AUTO_TAP_RANK else 0.0
        taps = min(TAP_CAP, manual + auto)
        gain = taps * g["tools"][tool - 1]["power"] * m * DT
        if pod_counts:
            gain += pod_rate * m * DT
        mp += gain
        lifetime += gain
        for r in g["ranks"]:
            if r["rank"] > rank and lifetime >= r["lifetime"]:
                rank = r["rank"]
                events.setdefault(f"rank_{rank}", t)
        t += DT

        if fight_end is not None:
            if t >= fight_end:
                coins += fight_boss["coins"]  # coinRebirthMult(0) = 1, no Coin Snack
                events.setdefault("first_win", t - (FIGHT_CYCLE - 3.0))  # win shows at 3 s
                events.setdefault(f"boss_{fight_boss['name']}", t - (FIGHT_CYCLE - 3.0))
                fight_end = None
            continue
        if t < busy_until:
            continue
        if coins >= g["rebirth_cost_1"] and not queue:
            events["rebirth_1"] = t
            break
        if queue and coins >= cost_of(queue[0]):
            item = queue.pop(0)
            coins -= cost_of(item)
            busy_until = t + WALK_SHOP
            events[item] = t + WALK_SHOP / 2  # bought at the stand, halfway
            kind, idx = item.split("_")
            if kind == "tool":
                tool = int(idx)
            elif kind == "pod":
                pod_rate = g["pods"][int(idx) - 1]["rate"]
            else:
                pet_bonus += g["basic_ev"]
            continue
        beatable = [b for b in w1 if mp >= b["need"]]
        if not beatable:
            continue
        boss = beatable[-1]
        if boss is not last_boss:
            last_boss = boss
            busy_until = t + WALK_BOSS
            continue
        fight_boss = boss
        fight_end = t + FIGHT_CYCLE
    return events


def fmt(sec: float | None) -> str:
    if sec is None:
        return "not reached"
    s = int(round(sec))
    return f"{s // 60}:{s % 60:02d}"


BASE_PLAN = ["tool_2", "pod_1", "tool_3", "egg_basic", "tool_4"]
KICKS_PLAN = BASE_PLAN + ["tool_5"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--luau-fixture", action="store_true", help="print tests/shared/Fixtures/GddTables.luau")
    args = ap.parse_args()
    g = load_gdd()
    if args.luau_fixture:
        sys.stdout.write(luau_fixture(g))
        return 0
    assert len(g["tools"]) == 12 and len(g["pods"]) == 7 and len(g["bosses"]) == 13 and len(g["ranks"]) == 12
    assert abs(g["basic_odds_sum"] - 1.0) < 1e-9, "Basic Egg odds do not sum to 100%"

    runs = []
    for tps in (5.0, 3.0):
        for pod_counts, label in ((True, "pod+boss"), (False, "boss-only")):
            for plan, plan_name in ((BASE_PLAN, "4.7 order"), (KICKS_PLAN, "+Fresh Kicks")):
                runs.append((tps, label, plan_name, simulate(g, tps, pod_counts, plan)))

    keys = ["first_win", "tool_2", "boss_Bedhead Benny", "pod_1", "tool_3", "rank_2", "boss_Sweatband Sal",
            "egg_basic", "tool_4", "boss_Captain Cardio", "rank_3", "tool_5", "rebirth_1"]
    head = ["Event", "GDD 4.7"] + [f"{int(r[0])}/s {r[1]} {r[2]}" for r in runs]
    rows = [[k, fmt(GDD_TIMES.get(k))] + [fmt(r[3].get(k)) for r in runs] for k in keys]
    if args.markdown:
        print("| " + " | ".join(head) + " |")
        print("|" + "---|" * len(head))
        for row in rows:
            print("| " + " | ".join(row) + " |")
    else:
        for row in [head] + rows:
            print("  ".join(c.ljust(14) for c in row))

    print()
    failed = 0
    for label, key, (lo, hi), rates in TARGETS:
        cells = []
        for tps, plabel, pname, ev in runs:
            if pname != "4.7 order" or (rates is not None and int(tps) not in rates):
                continue
            v = ev.get(key)
            tol = BAND_TOLERANCE if lo > 0 else 0.0
            strict_ok = v is not None and lo <= v <= hi
            ok = v is not None and lo - tol <= v <= hi + tol
            failed += 0 if ok else 1
            verdict = "PASS" if strict_ok else (f"PASS (within {tol:g} s of edge, D-052)" if ok else "FAIL")
            cells.append(f"{int(tps)}/s {plabel}: {fmt(v)} {verdict}")
        print(f"- {label}: " + "; ".join(cells))
    print(f"\nBasic Egg pet EV: +{g['basic_ev']:.4f}; rebirth 1 cost: {g['rebirth_cost_1']:.0f}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
