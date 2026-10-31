# Ads plan: first sponsored-ads test for "Aura Up!"

# NEEDS OWNER APPROVAL. THIS SPENDS MONEY (Robux). SPENDING REQUIRES OWNER APPROVAL.
_Owned by marketer. Written 2026-10-31. Proposal only: I do not set up, fund or run any campaign, and nothing here is approved. Human gate 3 applies (CLAUDE.md). The owner records approval in docs/decisions.md as `Approved by owner` before any Robux is spent._

## Recommendation: do NOT start before these four things are settled
1. **The 16+ trial question is understood.** (GDD R-1, legal 3.6.) Until the game passes Kids/Select evaluation (250 unique engaged plays by age-checked 16+ users within 60 days, plus the safety review), only age-checked 16+ users can see it. Ads can only reach people who can see the game, so early ads would buy 16+ traffic, not our 9-14 target. Also, I do not know whether paid ad clicks count as "highly engaged" plays for the 250 bar; the owner or Roblox help must confirm. Do not assume.
2. **Title clearance (NL-1).** Legal: formal clearance "before any ad spend or merch". The AURAUP application (Class 5) is still open. If the title may change, ad creatives and their review history would have to be redone.
3. **Lawyer reviews every ad creative** (legal section 7): real game only, no "free Robux", no reward mechanics for under-13s, no competitor names, no real people or the viral aura-farming likeness, no "looksmax" wording, no "Minimal" claim, no Mythic pulls shown as typical, no "money can't affect PvP" (say "Pets, multipliers, VIP and boosts do not count in duels").
4. **Week 1 data exists.** At least the first 7 days of organic data (launch-kit.md section 5): the first win time under 60 s, no save or purchase bugs, D1 at or above the 20% rough healthy line. Ads on a broken first 5 minutes just burn Robux.

Earliest sensible start: after Day 7 data review (about Nov 7) and only if items 1-3 are done. If the trial is still limited to 16+, treat the test below as a data-gathering test for the 250 bar, not a growth test.

## Things I could not verify (owner or Roblox Ads Manager must confirm before approving)
- The minimum daily budget, bid model (per impression or per click), and the age targeting options in Roblox's Sponsored Ads / Ads Manager. The amounts below are **my proposed caps**, not Roblox minimums. If the minimum is higher, the options shift up.
- What Robux amount in your account is "earned Robux". Robux spent on ads (and on the Kids/Select fee) reduces the Robux balance that matters for DevEx (legal section 6, unverified). Check before choosing.
- Whether ads can be set to only 16+ during the trial. If not, the ad would be shown to people who cannot open the game, which wastes spend.

## Common settings for all options
- **Placement:** sponsored game ad (the game's icon/thumbnail in discovery). Use the T1 "before/after" thumbnail and the icon from launch-kit.md. Make 2 variants at most: T1 vs T2 (ragdoll). Run them at the same time to compare.
- **Audience:** only audiences the game is allowed to reach. Respect Roblox's Advertising Standards. No targeting designed to push under-13 users.
- **No incentives:** no "codes for clicking" or reward mechanics in ads.
- **Daily cap:** every campaign has a hard daily cap equal to total budget divided by days. Never top up without a new approval.
- **Do not boost until the title is final.** Ads and thumbnails carry the name.

## Three budget options (all proposals, in Robux; owner picks one or none)

| | Option 1: Pilot | Option 2: Standard test | Option 3: Bigger test |
|---|---|---|---|
| Total budget | **500 R$** | **1,500 R$** | **3,000 R$** |
| Duration | 5 days (about 100 R$/day) | 7 days (about 215 R$/day) | 7 days (about 430 R$/day) |
| Creatives | 1 (T1 before/after) | 2 (T1 vs T2) | 2, plus a third variant if one wins after day 3 |
| Learns | Does the ad run at all, rough cost per click or visit, does a visitor reach the first win | Cost per engaged player, which thumbnail wins, D1 of ad players vs organic | Same, with enough volume (hundreds of visits) to read D1 and first-purchase rates with less noise |
| What I expect it buys | Not guessable: depends on bid/CPM. Treat result as the first price quote. | Same | Same |
| Best when | Trial is running, owner wants a cheap price check | Week 1 data healthy, NL-1 cleared | Trial passed (or Kids/Select visible), D1 at 25%+, the first purchase seen |
| Risk | Too small to read retention (maybe under 50 users) | Moderate | Highest spend; only after the stop rules below were met in an earlier test |

**Free baseline ("Option 0", 0 R$, always on):** organic only. Own social channels, 16+ friends, a clean game page, the weekly Saturday update. This is the launch plan in launch-kit.md.

My pick if the owner wants one: **Option 1 or nothing** until the trial question is answered. Option 3 only after Option 1 or 2 has met the continue rules.

## Metrics to read from the ad test
- **Cost per visit/play** (from the Ads dashboard, once the owner pastes it).
- **Cost per engaged player** = spend / players from the ad who reach the first rank-up (about 3 min of play). I compute it from analytics the owner pastes into `docs/marketing/analytics-<date>.md`.
- **D1 of ad players** vs organic players (compare with the rough 15-30% genre range; labeled rough).
- **First purchase rate** of ad players (rough 1-3%).
- **Trial counter movement** (engaged plays toward 250).

## Stop / continue rules (apply daily, owner makes the call)
**Stop immediately (pause the campaign) if any of these is true:**
- A bug that loses saves or fails purchase delivery is found (qa). Fix first.
- The lawyer or Roblox flags a creative.
- More than half of the budget is spent and fewer than 20 ad visits reached the first win. (Ad is shown, but the game is not converting; check the first 5 minutes.)
- Time to first win for ad players is over 2 min at the median.
- NL-1 turns into an objection or a rename is decided.

**Continue to the end of the test if all of these hold:**
- At least 70% of ad visitors reach the first boss win.
- D1 of ad players is within 5 points of organic D1, or at least 15% (rough).
- The cost per engaged player is stable day over day (no daily doubling).

**Scale up (go to the next option, needs a NEW owner approval) only if:**
- Cost per engaged player is acceptable to the owner AND D1 is 20%+ (rough) AND there are no bugs, AND the lawyer has re-cleared creatives, AND the trial/Kids-Select situation is understood.
- Do not scale on payer revenue alone: with a small sample, one big payer distorts it. A purchase must be a normal purchase by a real player, and ads must not drive purchases by pressure; all prices are as approved in D-038.

**What to change when the test is weak:**
- Many clicks, few first wins: the thumbnail promises something the first minute doesn't show. Change the thumbnail or the tutorial.
- First wins but low D1: the daily reward or Day 2 teaser is not seen, or the first rank-up is not landing.
- Cheap visits but no purchases: normal for the first week. Check Starter Pack pop-up visibility rather than adding more purchase prompts.

## Approval record (to be filled by team-lead, only by the owner's decision)
- Option chosen: ______ (or "none")
- Start date: ______
- Approved by owner: ______ (record in docs/decisions.md)
