#!/usr/bin/env python3
"""T-025 static exploit check: every C->S remote handler follows the architecture section 2 handler rules.

Owned by qa. Pure standard library, no Studio needed. Run from the repo (or worktree) root:

    python3 -I tests/static/check_handlers.py           # all C->S remotes
    python3 -I tests/static/check_handlers.py --strict  # PENDING (handler not written yet) also fails
    python3 -I tests/static/check_handlers.py --selftest  # runs on tests/static/selftest (must report FAILs)

Heuristic, file-level review aid (not a proof): for each C->S remote in src/shared/Contracts/Remotes.luau it
finds the server file that connects it (`RateLimit.connect("Name"` or `getEvent("Name")`) and checks that file
for the rules below. A FAIL is a review lead for qa to confirm, then file in docs/qa/bugs.md.
Repo-wide checks: no RemoteEvent/RemoteFunction created outside Contracts, no yield inside an Init().
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "src")
REMOTES = os.path.join(SRC, "shared", "Contracts", "Remotes.luau")
SELFTEST = os.path.join(ROOT, "tests", "static", "selftest")  # fake handlers (*.fixture), not synced or linted

# Remotes whose numeric arguments must be integers (architecture section 2)
INTEGER_ARGS = {"TapBatch", "BuyTool", "BuyPod", "HatchEgg", "DuelChallenge", "DuelRespond", "SetDuelBlock"}
# Remotes with a string argument that must be length-capped first
STRING_ARGS = {"RequestBossFight", "HatchEgg", "EquipPet", "DeletePets", "RequestPurchase", "RedeemCode", "SetSetting"}
# Remotes with no arguments: only the rate limit + DataLoaded rules apply
NO_ARGS = {"RequestRebirth", "ClaimDailyReward"}
# M1 focus (T-025): a PENDING handler for these is listed first
M1 = ["TapBatch", "RequestBossFight", "BuyTool"]

YIELDS = re.compile(r"task\.wait|wait\(|:WaitForChild\(|:Wait\(\)|Async\(|\.waitForData\(")


def c2s_remotes() -> list[str]:
    with open(REMOTES, encoding="utf-8") as f:
        text = f.read()
    return re.findall(r'^\s*(\w+)\s*=\s*\{[^}]*direction\s*=\s*"C2S"', text, re.M)


def luau_files(src: str) -> list[str]:
    out = []
    for base, _, files in os.walk(src):
        for name in files:
            if name.endswith((".luau", ".lua", ".fixture")):
                out.append(os.path.join(base, name))
    return sorted(out)


def read(path: str) -> str:
    """File text with Luau comments removed, so a comment that mentions a rule never counts as following it."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


def handler_file(name: str, files: dict[str, str]) -> str | None:
    pat = re.compile(r'(RateLimit\.connect|getEvent|RateLimit\.check)\(\s*(\w+\s*,\s*)?"' + name + '"')
    for path, text in files.items():
        if "/server/" in path.replace(os.sep, "/") and pat.search(text):
            return path
    return None


def check_remote(name: str, text: str) -> list[str]:
    problems = []
    if not re.search(r'RateLimit\.(connect|check)\([^)]*"' + name + '"', text):
        problems.append("no RateLimit.connect/check for this remote (rate limit before any work)")
    if not re.search(r"DataLoaded|isLoaded\(|getData\(", text):
        problems.append("no DataLoaded / DataService.isLoaded check")
    if name not in NO_ARGS and "typeof(" not in text and not re.search(r"type\(\w+\)\s*~=", text):
        problems.append("no typeof()/type() argument check")
    if name in INTEGER_ARGS:
        if not re.search(r"(\w+)\s*~=\s*\1\b|math\.huge|isFinite|finite", text):
            problems.append("no finite-number check (x ~= x / math.huge)")
        if not re.search(r"math\.floor\(|%\s*1\b|isInteger", text):
            problems.append("no integer check (math.floor / % 1)")
    if name in STRING_ARGS and not re.search(r"#\w+\s*[<>]=?|string\.len\(|utf8\.len\(", text):
        problems.append("no string length cap")
    return problems


def main() -> int:
    strict = "--strict" in sys.argv
    src = SELFTEST if "--selftest" in sys.argv else SRC
    files = {p: read(p) for p in luau_files(src)}
    remotes = c2s_remotes()
    order = M1 + [r for r in remotes if r not in M1]
    fails = pending = 0
    print("C->S handler rules (architecture section 2):")
    for name in order:
        path = handler_file(name, files)
        if path is None:
            pending += 1
            print(f"  PENDING {name}: no server handler yet")
            continue
        problems = check_remote(name, files[path])
        if problems:
            fails += 1
            print(f"  FAIL    {name} ({rel(path)}): " + "; ".join(problems))
        else:
            print(f"  PASS    {name} ({rel(path)})")

    print("Repo-wide:")
    for path, text in files.items():
        unix = path.replace(os.sep, "/")
        if "/shared/Contracts/" not in unix and re.search(r'Instance\.new\(\s*"Remote(Event|Function)"', text):
            fails += 1
            print(f"  FAIL    {rel(path)}: creates a RemoteEvent/RemoteFunction outside Contracts/Remotes.luau")
        if "/shared/Contracts/" not in unix and re.search(r"OnServerEvent:Connect", text) and "RateLimit" not in text:
            fails += 1
            print(f"  FAIL    {rel(path)}: OnServerEvent:Connect without RateLimit")
        for m in re.finditer(r"function\s+[\w.:]+[.:]Init\s*\([^)]*\)(.*?)\nend\b", text, re.S):
            if YIELDS.search(m.group(1)):
                fails += 1
                line = text[: m.start()].count("\n") + 1
                print(f"  FAIL    {rel(path)}:{line}: Init() yields (task.wait / WaitForChild / Wait / *Async)")
    print(f"\nSTATIC RESULT: {fails} fail, {pending} pending, {len(remotes)} C->S remotes")
    return 1 if fails or (strict and pending) else 0


if __name__ == "__main__":
    sys.exit(main())
