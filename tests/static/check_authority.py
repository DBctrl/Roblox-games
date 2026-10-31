#!/usr/bin/env python3
"""T-046 static authority check: egg rolls and currency stay on the server, and PetService refreshes M (QA-5).

Owned by qa. Pure standard library, no Studio needed. Run from the repo (or worktree) root:

    python3 -I tests/static/check_authority.py            # checks src/
    python3 -I tests/static/check_authority.py --strict   # PENDING (PetService not written yet) also fails
    python3 -I tests/static/check_authority.py --selftest # runs on tests/static/selftest/authority
      expected: "2 fail, 0 pending". BadEggController FAILs with 5 problems (roll fn, random next to weights,
      SetAttribute Coins, leaderstats write, FireServer with an amount); PetService FAILs once (setEquipped calls
      removeFromEquipped with no refresh). GoodEggController and PetService.deletePets (refresh via a helper) pass.

Heuristic, file-level review aid (not a proof). A FAIL is a lead for qa to confirm, then file in docs/qa/bugs.md.
Checks (architecture 0, 4b; CR-c / QA-5):
  client-roll      no client file defines a roll/hatch-roll function, or calls a random source
                   (math.random, Random.new, :NextInteger, :NextNumber) within 6 lines of egg weights / ODDS_TOTAL
  shared-roll      same, in src/shared (the roll needs the one server Random owned by PetService, 4b)
  client-currency  no client SetAttribute of a Types.PlayerAttr name, no leaderstats .Value write, no DataStore
                   or ProcessReceipt use, no FireServer argument named like an amount/price/result/seed
  qa5-refresh      in Gameplay/PetService, every function that changes `equipped` or removes an inventory entry
                   calls MultiplierService.refresh (directly, through a local helper that does, or every caller of
                   it does)
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SELFTEST = os.path.join(ROOT, "tests", "static", "selftest", "authority")
TYPES = os.path.join(ROOT, "src", "shared", "Contracts", "Types.luau")

RANDOM = re.compile(r"math\.random\s*\(|Random\.new\s*\(|:\s*NextInteger\s*\(|:\s*NextNumber\s*\(")
ODDS = re.compile(r"\.weight\b|ODDS_TOTAL|EGGS\s*\[|\.pets\b")
ROLL_FN = re.compile(r"^\s*(?:local\s+)?function\s+[\w.:]*(?:[Rr]oll\w*|[Pp]ickPet\w*|[Hh]atchRoll\w*)\s*\(", re.M)
WINDOW = 6

SET_ATTR = re.compile(r":\s*SetAttribute\s*\(\s*(?:\"(\w+)\"|[\w.]*Attr\w*\.(\w+))")
LEADERSTATS_WRITE = re.compile(r"leaderstats.*\.Value\s*=(?!=)")
SERVER_ONLY = re.compile(r"DataStoreService|ProcessReceipt|GetDataStore|GetOrderedDataStore")
FIRE_SERVER = re.compile(r":\s*FireServer\s*\(([^)]*)\)")
AMOUNTISH = re.compile(r"\b\w*(?:[Cc]oins?|[Aa]mount|[Pp]rice|[Cc]ost|[Rr]eward|[Rr]esult|[Ss]eed|[Rr]oll|[Mm]ultiplier)\w*\b")

FUNC_START = re.compile(r"^(?:local\s+)?function\s+([\w.:]+)\s*\(")
EQUIP_MUTATION = re.compile(
    r"table\.(?:insert|remove|clear)\s*\(\s*[\w.\[\]\"]*equipped"
    r"|\bequipped\s*=(?!=)"
    r"|\bequipped\s*\[[^\]]+\]\s*=(?!=)"
    r"|\binventory\s*\[[^\]]+\]\s*=\s*nil\b"
)
REFRESH = re.compile(r"[Mm]ultiplier\w*\s*[.:]\s*refresh\s*\(|\bMS\s*[.:]\s*refresh\s*\(")


def player_attrs() -> set[str]:
    try:
        text = open(TYPES, encoding="utf-8").read()
    except OSError:
        return set()
    block = re.search(r"Types\.PlayerAttr\s*=\s*table\.freeze\(\{(.*?)\}\)", text, re.S)
    return set(re.findall(r"^\s*(\w+)\s*=", block.group(1), re.M)) if block else set()


def luau_files(folder: str, exts: tuple[str, ...]) -> list[str]:
    out = []
    for base, _dirs, names in os.walk(folder):
        for n in names:
            if n.endswith(exts):
                out.append(os.path.join(base, n))
    return sorted(out)


def strip_comments(text: str) -> str:
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


def roll_problems(text: str) -> list[str]:
    problems = []
    lines = text.split("\n")
    m = ROLL_FN.search(text)
    if m:
        problems.append(f"line {text[: m.start()].count(chr(10)) + 1}: defines a roll function")
    odds_lines = [i for i, line in enumerate(lines) if ODDS.search(line)]
    for i, line in enumerate(lines):
        if RANDOM.search(line) and any(abs(i - j) <= WINDOW for j in odds_lines):
            problems.append(f"line {i + 1}: random source next to egg weights")
            break
    return problems


def currency_problems(text: str, attrs: set[str]) -> list[str]:
    problems = []
    for i, line in enumerate(text.split("\n"), 1):
        for m in SET_ATTR.finditer(line):
            name = m.group(1) or m.group(2)
            if name in attrs:
                problems.append(f"line {i}: client SetAttribute({name}) (server-owned PlayerAttr)")
        if LEADERSTATS_WRITE.search(line):
            problems.append(f"line {i}: client writes a leaderstats value")
        if SERVER_ONLY.search(line):
            problems.append(f"line {i}: DataStore/ProcessReceipt in client code")
        for m in FIRE_SERVER.finditer(line):
            bad = AMOUNTISH.findall(m.group(1))
            if bad:
                problems.append(f"line {i}: FireServer sends {', '.join(bad)} (intents only, architecture 0)")
    return problems


def blocks(text: str) -> list[tuple[str, int, str]]:
    """Top-level function blocks: (name, start line, body). A block runs to the next top-level function."""
    out: list[tuple[str, int, list[str]]] = []
    for i, line in enumerate(text.split("\n"), 1):
        m = FUNC_START.match(line)
        if m:
            out.append((m.group(1), i, [line]))
        elif out:
            out[-1][2].append(line)
    return [(n, s, "\n".join(b)) for n, s, b in out]


def qa5_problems(text: str) -> list[str]:
    bl = blocks(text)
    short = {name: re.split(r"[.:]", name)[-1] for name, _s, _b in bl}
    refreshers = {short[n] for n, _s, b in bl if REFRESH.search(b)}
    # one more level: a helper that calls a refresher also refreshes
    for n, _s, b in bl:
        if any(re.search(rf"\b{re.escape(r)}\s*\(", b) for r in refreshers if r != short[n]):
            refreshers.add(short[n])
    # A mutating helper with callers moves the duty to its callers (one level); one without callers keeps it.
    starts = {n: s for n, s, _b in bl}
    duty: dict[str, str] = {}
    for name, _start, body in bl:
        if not EQUIP_MUTATION.search(body):
            continue
        callers = [n2 for n2, _s2, b2 in bl if n2 != name and re.search(rf"\b{re.escape(short[name])}\s*\(", b2)]
        for n in callers or [name]:
            duty.setdefault(n, "changes equipped/inventory" if n == name else f"calls {short[name]}")
    return [
        f"{n} (line {starts[n]}) {why} without MultiplierService.refresh"
        for n, why in sorted(duty.items(), key=lambda kv: starts[kv[0]])
        if short[n] not in refreshers
    ]


def run(src: str, strict: bool, attrs: set[str]) -> tuple[int, int]:
    fails = pending = 0
    exts = (".luau", ".lua", ".fixture")
    print("client-roll / client-currency (src/client):")
    for path in luau_files(os.path.join(src, "client"), exts):
        text = strip_comments(open(path, encoding="utf-8").read())
        probs = roll_problems(text) + currency_problems(text, attrs)
        if probs:
            fails += 1
            print(f"  FAIL    {rel(path)}: " + "; ".join(probs))
    print("shared-roll (src/shared):")
    for path in luau_files(os.path.join(src, "shared"), exts):
        probs = roll_problems(strip_comments(open(path, encoding="utf-8").read()))
        if probs:
            fails += 1
            print(f"  FAIL    {rel(path)}: " + "; ".join(probs))
    print("qa5-refresh (Gameplay/PetService):")
    pet = next(
        (p for p in luau_files(os.path.join(src, "server", "Gameplay"), exts)
         if os.path.basename(p).split(".")[0] == "PetService"),
        None,
    )
    if pet is None:
        pending += 1
        print("  PENDING PetService: not written yet (T-028)")
    else:
        text = strip_comments(open(pet, encoding="utf-8").read())
        probs = qa5_problems(text)
        if not EQUIP_MUTATION.search(text):
            probs.append("no equip/unequip/delete mutation found (checker blind spot? review by hand)")
        if probs:
            fails += len(probs)
            for p in probs:
                print(f"  FAIL    {rel(pet)}: {p}")
        else:
            print(f"  PASS    {rel(pet)}")
    if strict:
        fails += pending
    return fails, pending


def main() -> int:
    selftest = "--selftest" in sys.argv
    strict = "--strict" in sys.argv
    src = SELFTEST if selftest else os.path.join(ROOT, "src")
    fails, pending = run(src, strict, player_attrs())
    print(f"\nAUTHORITY RESULT: {fails} fail, {pending} pending")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
