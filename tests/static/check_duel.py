#!/usr/bin/env python3
"""T-068 static duel and daily-reward check (architecture 2 #9-#14, 4c; GDD 6, 10).

Owned by qa. Pure standard library, no Studio needed. Run from the repo (or worktree) root:

    python3 -I tests/static/check_duel.py            # checks src/
    python3 -I tests/static/check_duel.py --strict   # PENDING (service not written yet) also fails
    python3 -I tests/static/check_duel.py --selftest # runs on tests/static/selftest/duel
      expected: "9 fail, 0 pending". the DuelService fixture FAILs score-inputs (getPetMultiplierSum, paidTier, hypeSec),
      reward-caps, forfeit, self-duel, tap-clamp and pve-mp; the RewardService fixture FAILs client-time, vip-coins and
      utc-day.

Heuristic, file-level review aid (not a proof). A FAIL is a lead for qa to confirm, then file in docs/qa/bugs.md.
DuelService (Gameplay/DuelService):
  score-inputs  never reads pets, multipliers, the paid tier, VIP or boosts (score = taps and ranks only, 4c)
  reward-caps   reward path uses DUEL_REWARDS_PER_HOUR and DUEL_REWARDS_PER_OPPONENT (or DuelRules.rewardAllowed)
  forfeit       connects Players.PlayerRemoving and calls ZoneService.releaseRing (forfeit on leave, ring released)
  self-duel     compares the target with the sender (UserId == / ~=, or target == player)
  tap-clamp     uses DUEL_TAP_CAP_PER_SEC (or DuelRules.acceptTaps)
  pve-mp        never calls TapService.addMp (no PvE MP from duel taps)
RewardService (Gameplay/RewardService):
  client-time   the ClaimDailyReward handler takes no argument after `player` (the server clock decides, #14)
  vip-coins     no line that mentions VIP also mentions coins or addCoins (VIP adds Hype only, GDD 10)
  utc-day       the claim reads a server clock (os.time / DateTime / GetServerTimeNow) and `lastClaimDay`
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SELFTEST = os.path.join(ROOT, "tests", "static", "selftest", "duel")
EXTS = (".luau", ".lua", ".fixture")

SCORE_FORBIDDEN = re.compile(
    r"getPetMultiplierSum|getMpMultiplier|getCoinMultiplier|\bpaidTier\b|getPaidTier|PaidTier\b|hasVip|\bvip\b"
    r"|\bVip\b|hypeSec|speedSec|\bboosts\b|AutoClickerOwned|PetMult|EquippedBonus"
)


def strip_comments(text: str) -> str:
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def find(server: str, name: str) -> str | None:
    for base, _dirs, names in os.walk(os.path.join(server, "Gameplay")):
        for n in names:
            if n.endswith(EXTS) and n.split(".")[0] == name:
                return os.path.join(base, n)
    return None


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


def line_of(text: str, rx: re.Pattern[str]) -> list[int]:
    return [i for i, line in enumerate(text.split("\n"), 1) if rx.search(line)]


def duel_problems(text: str) -> list[str]:
    probs = []
    hits = line_of(text, SCORE_FORBIDDEN)
    if hits:
        probs.append(f"score-inputs: reads pets/paid/VIP/boosts at line(s) {', '.join(map(str, hits[:6]))}")
    if not (("DUEL_REWARDS_PER_HOUR" in text and "DUEL_REWARDS_PER_OPPONENT" in text) or "rewardAllowed" in text):
        probs.append("reward-caps: no DUEL_REWARDS_PER_HOUR + DUEL_REWARDS_PER_OPPONENT (or rewardAllowed) check")
    if not (re.search(r"PlayerRemoving", text) and re.search(r"releaseRing\s*\(", text)):
        probs.append("forfeit: no PlayerRemoving handler with releaseRing (forfeit on leave, ring released)")
    if not re.search(r"UserId\s*[=~]=|[=~]=\s*\w+\.UserId|\btarget\w*\s*[=~]=\s*player\b|\bplayer\s*[=~]=\s*target", text):
        probs.append("self-duel: no target-vs-sender comparison found")
    if not ("DUEL_TAP_CAP_PER_SEC" in text or "acceptTaps" in text):
        probs.append("tap-clamp: DUEL_TAP_CAP_PER_SEC (or acceptTaps) never used")
    if re.search(r"\baddMp\s*\(", text):
        probs.append("pve-mp: calls addMp (duel taps must not earn PvE MP)")
    return probs


def reward_problems(text: str) -> list[str]:
    probs = []
    m = re.search(r"\"ClaimDailyReward\"[^\n]*?function\s*\(([^)]*)\)", text)
    if m:
        params = [p.strip() for p in m.group(1).split(",") if p.strip()]
        extra = [p for p in params[1:] if not p.startswith("_") and p != "..."]
        if extra:
            probs.append(f"client-time: ClaimDailyReward handler takes {', '.join(extra)} after player")
    for i, line in enumerate(text.split("\n"), 1):
        if re.search(r"\b[Vv]ip\b|hasVip|VIP", line) and re.search(r"\bcoins\b|addCoins|[Cc]oinSec", line):
            probs.append(f"vip-coins: line {i} ties VIP to coins")
    if not re.search(r"os\.time\s*\(|DateTime\.now\s*\(|GetServerTimeNow", text) or "lastClaimDay" not in text:
        probs.append("utc-day: no server clock or no lastClaimDay comparison")
    return probs


def run(src: str, strict: bool) -> tuple[int, int]:
    fails = pending = 0
    server = os.path.join(src, "server")
    for name, check in (("DuelService", duel_problems), ("RewardService", reward_problems)):
        print(f"{name}:")
        path = find(server, name)
        if path is None:
            pending += 1
            print(f"  PENDING {name}: not written yet")
            continue
        probs = check(strip_comments(open(path, encoding="utf-8").read()))
        if probs:
            fails += len(probs)
            for p in probs:
                print(f"  FAIL    {rel(path)}: {p}")
        else:
            print(f"  PASS    {rel(path)}")
    if strict:
        fails += pending
    return fails, pending


def main() -> int:
    selftest = "--selftest" in sys.argv
    strict = "--strict" in sys.argv
    src = SELFTEST if selftest else os.path.join(ROOT, "src")
    fails, pending = run(src, strict)
    print(f"\nDUEL RESULT: {fails} fail, {pending} pending")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
