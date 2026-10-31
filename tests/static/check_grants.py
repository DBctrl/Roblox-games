#!/usr/bin/env python3
"""T-081 static coin firewall and purchase-flow check (GDD 8g, D-021, architecture 3c / 4e / 4f, legal RC-1 (c)).

Owned by qa. Pure standard library, no Studio needed. Run from the repo (or worktree) root:

    python3 -I tests/static/check_grants.py            # checks src/
    python3 -I tests/static/check_grants.py --strict   # PENDING (grant or service not written yet) also fails
    python3 -I tests/static/check_grants.py --selftest # runs on tests/static/selftest/grants
      expected: "5 fail, 2 pending". BadGrants FAILs PaidTier (writes coins, no ladderGrant), Boost (yields),
      RobuxEgg (no restrictedGrant / paidRandomAllowed, calls tryHatch) and Entitlement (nested DataService.update
      through a helper); the fixture MonetizationService FAILs once (`NotYetProcessed`). GoodGrants passes
      FixedPet and StarterPack (StarterPack names `data.coins` only inside a comment). Donation and the
      ProcessReceipt owner are PENDING there by design.

Heuristic, file-level review aid (not a proof). A FAIL is a lead for qa to confirm, then file in docs/qa/bugs.md.
Checks:
  grant-firewall  every `registerGrant("Kind", fn)` in src/server: the fn body, and the bodies of local helpers it
                  calls (3 levels), never names coins / addCoins / trySpendCoins / toolIndex / podsMask / rebirths /
                  world2Unlocked / tryHatch / coinSec / a "Coin" boost / getCoinMultiplier / a CoinReason; never
                  yields; never calls DataService.update / saveAndConfirm / waitForData (grant fns mutate the
                  `data` they are handed, synchronously, architecture 1b)
  grant-kinds     each Types.GrantKind is registered exactly once (missing = PENDING, twice = FAIL)
  grant-rules     PaidTier uses ProductCatalog.ladderGrant (D-019 #3); RobuxEgg uses restrictedGrant and reads
                  paidRandomAllowed (GDD 5, D-016 #4)
  receipt         ProcessReceipt assigned exactly once, in Data/MonetizationService; the Roblox enum item is
                  `NotProcessedYet` (nothing may write `NotYetProcessed`, which does not exist and errors at runtime)
  catalog         ProductCatalog prices equal D-038; every Robux egg's restrictedPetId equals
                  EconomyConfig.EGGS[eggId].restrictedGrant; no other src file holds a product id literal
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SELFTEST = os.path.join(ROOT, "tests", "static", "selftest", "grants")
TYPES = os.path.join(ROOT, "src", "shared", "Contracts", "Types.luau")
CATALOG = os.path.join(ROOT, "src", "shared", "Contracts", "ProductCatalog.luau")
ECONOMY = os.path.join(ROOT, "src", "shared", "Gameplay", "EconomyConfig.luau")
EXTS = (".luau", ".lua", ".fixture")

D038 = {
    "MpX2": 4, "MpX4": 8, "MpX8": 19, "MpX16": 39, "MpX32": 79, "HypeSnack": 2, "StarterPack": 9,
    "RingLightRetriever": 29, "AutoClicker": 39, "Vip": 99, "GoldenGlowFit": 249,
    "StarEgg1": 25, "StarEgg3": 69, "GalaxyEgg1": 49, "GalaxyEgg3": 129,
}
FALLBACK_KINDS = ["PaidTier", "Entitlement", "Boost", "FixedPet", "StarterPack", "RobuxEgg", "Donation"]

FORBIDDEN = [
    (re.compile(r"\bcoins\b"), "coins"),
    (re.compile(r"\baddCoins\b|\btrySpendCoins\b"), "a coin API"),
    (re.compile(r"\btoolIndex\b"), "toolIndex (coin-shop tool)"),
    (re.compile(r"\bpodsMask\b|\btryBuyPod\b"), "podsMask (coin-shop pod)"),
    (re.compile(r"\brebirths\b|\btryRebirth\b"), "rebirths"),
    (re.compile(r"\bworld2Unlocked\b|\bteleportToWorld\b"), "world2Unlocked"),
    (re.compile(r"\btryHatch\b"), "a coin-egg hatch (tryHatch)"),
    (re.compile(r"\bcoinSec\b|addBoost\s*\([^)]*\"Coin\""), "a Coin Snack boost"),
    (re.compile(r"\bgetCoinMultiplier\b"), "the coin multiplier"),
    (re.compile(r"\"(?:BossWin|DuelReward|Daily|Code)\""), "a CoinReason"),
]
YIELDS = re.compile(r"task\.wait|\bwait\s*\(|:\s*Wait\s*\(|Async\s*\(|\bwaitForData\b|\bsaveAndConfirm\b")
NESTED = re.compile(r"\b(?:DataService|[Dd]ata[Aa]pi|Deps\.data\(\))\s*[.:]\s*update\s*\(|\bdata\(\)\s*\.\s*update\s*\(")

REGISTER = re.compile(r"registerGrant\s*\(\s*\"(\w+)\"\s*,\s*(function\b|[\w.:]+)")
FUNC_DEF = re.compile(r"^(\s*)(?:local\s+)?function\s+([\w.:]+)\s*\(|^(\s*)local\s+(\w+)\s*=\s*function\s*\(")
INLINE_FN = re.compile(r"function\s*\(")


def strip_comments(text: str) -> str:
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def luau_files(folder: str) -> list[str]:
    out = []
    for base, _dirs, names in os.walk(folder):
        for n in names:
            if n.endswith(EXTS):
                out.append(os.path.join(base, n))
    return sorted(out)


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


def indent(line: str) -> int:
    return len(line) - len(line.lstrip("\t "))


def body_from(lines: list[str], start: int) -> str:
    """Body of the function opening on line `start` (0-based): up to the first later line with the same indentation
    that starts with `end` (StyLua formatting). A one-line `function() ... end` is its own body."""
    first = lines[start]
    m = INLINE_FN.search(first)
    if m and re.search(r"\bend\b", first[m.end():]):
        return first
    ind = indent(first)
    out = [first]
    for line in lines[start + 1:]:
        out.append(line)
        if line.strip().startswith("end") and indent(line) == ind:
            break
    return "\n".join(out)


def local_functions(lines: list[str]) -> dict[str, str]:
    """name (last segment) -> body, for every function defined in the file."""
    out: dict[str, str] = {}
    for i, line in enumerate(lines):
        m = FUNC_DEF.match(line)
        if m:
            name = (m.group(2) or m.group(4) or "")
            out.setdefault(re.split(r"[.:]", name)[-1], body_from(lines, i))
    return out


def with_helpers(body: str, funcs: dict[str, str], own: str | None, depth: int = 3) -> str:
    """The body plus the bodies of same-file functions it calls, `depth` levels deep."""
    seen = {own} if own else set()
    parts = [body]
    frontier = [body]
    for _ in range(depth):
        nxt = []
        for b in frontier:
            for name, fb in funcs.items():
                if name in seen or not re.search(rf"(?<![\w]){re.escape(name)}\s*\(", b):
                    continue
                seen.add(name)
                parts.append(fb)
                nxt.append(fb)
        frontier = nxt
    return "\n".join(parts)


def grant_kinds() -> list[str]:
    try:
        text = open(TYPES, encoding="utf-8").read()
    except OSError:
        return FALLBACK_KINDS
    m = re.search(r"export type GrantKind\s*=(.*?)\n\n", text, re.S)
    kinds = re.findall(r"\"(\w+)\"", m.group(1)) if m else []
    return kinds or FALLBACK_KINDS


def find_registrations(server: str) -> list[tuple[str, str, int, str]]:
    """(kind, file, line, fn body incl. helpers) for every registerGrant call."""
    regs = []
    for path in luau_files(server):
        text = strip_comments(open(path, encoding="utf-8").read())
        lines = text.split("\n")
        funcs = local_functions(lines)
        for i, line in enumerate(lines):
            for m in REGISTER.finditer(line):
                kind, target = m.group(1), m.group(2)
                if target == "function":
                    body = body_from(lines, i)
                    own = None
                else:
                    own = re.split(r"[.:]", target)[-1]
                    body = funcs.get(own, "")
                    if not body:
                        regs.append((kind, path, i + 1, "\0unresolved " + target))
                        continue
                regs.append((kind, path, i + 1, with_helpers(body, funcs, own)))
    return regs


def grant_problems(kind: str, body: str) -> list[str]:
    probs = []
    for rx, what in FORBIDDEN:
        if rx.search(body):
            probs.append(f"touches {what}")
    if YIELDS.search(body):
        probs.append("yields (grant fns are synchronous)")
    if NESTED.search(body):
        probs.append("calls DataService.update inside a grant (nested update)")
    if kind == "PaidTier" and "ladderGrant" not in body:
        probs.append("does not use ProductCatalog.ladderGrant (D-019 #3)")
    if kind == "RobuxEgg":
        if "restrictedGrant" not in body:
            probs.append("no restrictedGrant path for restricted players (GDD 5)")
        if not re.search(r"paidRandomAllowed|PaidRandomAllowed", body):
            probs.append("never reads paidRandomAllowed (restricted players would get a roll)")
    return probs


def check_grants(server: str, strict: bool) -> tuple[int, int]:
    fails = pending = 0
    regs = find_registrations(server)
    print("grant-firewall / grant-rules (registerGrant bodies):")
    for kind, path, line, body in regs:
        if body.startswith("\0unresolved"):
            fails += 1
            print(f"  FAIL    {kind} ({rel(path)}:{line}): grant fn {body.split()[-1]} not found in the file")
            continue
        probs = grant_problems(kind, body)
        if probs:
            fails += 1
            print(f"  FAIL    {kind} ({rel(path)}:{line}): " + "; ".join(probs))
        else:
            print(f"  PASS    {kind} ({rel(path)}:{line})")
    print("grant-kinds (each Types.GrantKind registered once):")
    for kind in grant_kinds():
        n = sum(1 for k, *_ in regs if k == kind)
        if n == 0:
            pending += 1
            print(f"  PENDING {kind}: no registerGrant yet")
        elif n > 1:
            fails += 1
            print(f"  FAIL    {kind}: registered {n} times")
    unknown = sorted({k for k, *_ in regs} - set(grant_kinds()))
    for k in unknown:
        fails += 1
        print(f"  FAIL    registerGrant(\"{k}\"): not a Types.GrantKind")
    if strict:
        fails += pending
    return fails, pending


def check_receipt(src: str, strict: bool) -> tuple[int, int]:
    fails = pending = 0
    print("receipt (ProcessReceipt owner, enum names):")
    owners = []
    for path in luau_files(src):
        text = strip_comments(open(path, encoding="utf-8").read())
        for i, line in enumerate(text.split("\n"), 1):
            if re.search(r"\.ProcessReceipt\s*=(?!=)", line):
                owners.append((path, i))
            if "NotYetProcessed" in line:
                fails += 1
                print(f"  FAIL    {rel(path)}:{i}: `NotYetProcessed` is not a ProductPurchaseDecision item "
                      "(use Enum.ProductPurchaseDecision.NotProcessedYet)")
    if not owners:
        pending += 1
        print("  PENDING ProcessReceipt: not assigned yet (T-056)")
    else:
        for path, i in owners:
            ok = os.path.basename(path).split(".")[0] == "MonetizationService" and len(owners) == 1
            if not ok:
                fails += 1
            print(f"  {'PASS   ' if ok else 'FAIL   '} ProcessReceipt assigned at {rel(path)}:{i}"
                  + ("" if ok else " (must be once, in Data/MonetizationService)"))
    if strict:
        fails += pending
    return fails, pending


def lua_table_block(text: str, start_pat: str) -> str:
    m = re.search(start_pat, text)
    if not m:
        return ""
    i = text.index("{", m.end() - 1)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return ""


def check_catalog(src: str) -> int:
    fails = 0
    print("catalog (D-038 prices, restricted pets, ids in one place):")
    try:
        cat = strip_comments(open(CATALOG, encoding="utf-8").read())
        eco = strip_comments(open(ECONOMY, encoding="utf-8").read())
    except OSError as e:
        print(f"  FAIL    cannot read {e.filename}")
        return 1
    prices: dict[str, int] = {}
    for key, _tier, price in re.findall(r"(\w+)\s*=\s*ladder\(\"\w+\",\s*(\d+),\s*(\d+)\)", cat):
        prices[key] = int(price)
    for key, _egg, _count, price, pet in re.findall(
        r"(\w+)\s*=\s*robuxEgg\(\"\w+\",\s*\"(\w+)\",\s*(\d+),\s*(\d+),\s*\"(\w+)\"", cat
    ):
        prices[key] = int(price)
    for key, body in re.findall(r"(\w+)\s*=\s*entry\(\{(.*?)\}\),", cat, re.S):
        m = re.search(r"priceRobux\s*=\s*(\d+)", body)
        if m:
            prices[key] = int(m.group(1))
    on_sale_off = re.findall(r"(\w+)\s*=\s*notOnSale\(", cat)
    for key, price in D038.items():
        if prices.get(key) != price:
            fails += 1
            print(f"  FAIL    {key}: catalog price {prices.get(key)} R$, D-038 says {price} R$")
    for key in sorted(set(prices) - set(D038)):
        fails += 1
        print(f"  FAIL    {key}: on sale at {prices[key]} R$ without an owner price approval (gate 5)")
    eggs_restricted = {}
    for egg in ("StarEgg", "GalaxyEgg"):
        block = lua_table_block(eco, rf"\b{egg}\s*=\s*\{{")
        m = re.search(r"restrictedGrant\s*=\s*\"(\w+)\"", block)
        eggs_restricted[egg] = m.group(1) if m else None
    for key, egg, count, _price, pet in re.findall(
        r"(\w+)\s*=\s*robuxEgg\(\"\w+\",\s*\"(\w+)\",\s*(\d+),\s*(\d+),\s*\"(\w+)\"", cat
    ):
        if eggs_restricted.get(egg) != pet:
            fails += 1
            print(f"  FAIL    {key}: restrictedPetId {pet}, EconomyConfig.EGGS.{egg}.restrictedGrant "
                  f"{eggs_restricted.get(egg)}")
        if count not in ("1", "3"):
            fails += 1
            print(f"  FAIL    {key}: count {count}")
    for path in luau_files(src):
        if os.path.abspath(path) == os.path.abspath(CATALOG):
            continue
        text = strip_comments(open(path, encoding="utf-8").read())
        for i, line in enumerate(text.split("\n"), 1):
            if re.search(r"\b(?:productId|ProductId)\s*=\s*[1-9]\d{3,}", line) or re.search(
                r"PromptProductPurchase\s*\([^,]*,\s*\d{4,}", line
            ):
                fails += 1
                print(f"  FAIL    {rel(path)}:{i}: product id literal outside ProductCatalog (D-054)")
    if fails == 0:
        print(f"  PASS    15 D-038 prices, {len(on_sale_off)} not on sale, restricted pets match EconomyConfig")
    return fails


def main() -> int:
    selftest = "--selftest" in sys.argv
    strict = "--strict" in sys.argv
    src = SELFTEST if selftest else os.path.join(ROOT, "src")
    f1, p1 = check_grants(os.path.join(src, "server"), strict)
    f2, p2 = check_receipt(src, strict)
    f3 = 0 if selftest else check_catalog(src)
    fails, pending = f1 + f2 + f3, p1 + p2
    print(f"\nGRANT RESULT: {fails} fail, {pending} pending")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
