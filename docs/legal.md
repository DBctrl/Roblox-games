# Legal and compliance
_Owned by lawyer._

> This is not legal advice. It is an automated compliance checklist. Consult a qualified lawyer for anything flagged NEEDS-LAWYER.

## GDD review: Candy Factory Tycoon (docs/gdd.md, D-007), 2026-10-31

> This is not legal advice. It is an automated compliance checklist. Consult a qualified lawyer for anything flagged NEEDS-LAWYER.

**Sources and verification.** Policies are cited by name from the reviewer's knowledge: Roblox Terms of Use,
Roblox Community Standards, Roblox Paid Random Items policy, Experience Guidelines / Content Maturity Labels
questionnaire, Developer Exchange (DevEx) Terms, Roblox Advertising Standards. **The current text of these
pages was not fetched live in this review**, so every point below should be re-checked against the live
pages at `/launch`. No marketing docs, assets or analytics fields exist yet (docs/marketing/ empty,
asset log and architecture.md empty), so items 4, 5 and 7 cover the GDD only.

### NEEDS-LAWYER
- None. Nothing in the GDD needs a qualified lawyer at this stage.

### Summary
| # | Item | Status |
|---|---|---|
| 1 | Terms of Use / Community Standards | RISK (group-join bonus) |
| 2 | Monetization | RISK (lower-tier pass purchases, Top Donors amounts) |
| 3 | Maturity label | PASS (likely Minimal) |
| 4 | IP / trademark | PASS (low risk, generic name) |
| 5 | Privacy | RISK (public R$ spend of minors on Top Donors) |
| 6 | DevEx | PASS (notes only) |
| 7 | Advertising | PASS (nothing to review yet) |

No BLOCKERs. All RISK items have a recommended safe option below; monetization risks escalate to the owner.

### 1. Terms of Use and Community Standards: RISK
- Content: cartoon candy factory, no violence, no blood, no gambling theme, no romance. PASS.
- Social: no custom text input, no chat-dependent mechanics, no off-platform links, no trading. Plot
  griefing prevented (only the owner presses pads). PASS.
- **Group-join bonus (+10% earnings for group members): RISK.** Roblox rules (Community Standards on
  misusing Roblox systems / artificially inflating engagement, and the developer rules on incentivized
  engagement) forbid giving in-experience rewards for likes, favourites, ratings or follows. Whether a
  *gameplay* reward for joining a group is still allowed is not clear to me from memory, and the
  current text could not be verified. Many live games do it, but that is not evidence it is allowed.
  **Safe option (ruled in D-008):** no gameplay reward for joining the group in v1. Allowed: a plain,
  optional "Join our group for update news" button with no reward. If the owner wants a group perk
  later, re-verify the live policy first and prefer a cosmetic-only perk (for example a name-sign tint).
- GDD already bans rewards for likes/favourites/ratings. PASS; keep it that way (no "like for a code" either
  when the codes system arrives in Update 1).

### 2. Monetization: RISK
- **Paid random items:** none (no crates, eggs, paid luck). Paid Random Items policy not triggered. PASS.
- **Premium currency / Robux value:** none; nothing implies Robux can be won or exchanged for real value. PASS.
- **Pay to avoid punishment:** no punishment exists (no death, no loss, no AFK kick). PASS.
- **Progression without paying:** free player reaches Rebirth 10 in ~9-10 h; every system is reachable
  free. Passes speed up, they never gate. Roblox does not prohibit "pay to win" as such. PASS.
- **Multiplier ladder pricing (4/8/16/32 R$):** prices are deterministic and shown by Roblox's purchase
  prompt. Fine in principle. Check at setup that 4 R$ is at or above the current game-pass minimum price
  (could not verify the current minimum). PASS with that check.
- **"Highest tier applies" + "buying any tier is allowed": RISK.** A player who owns x8 could buy x2 or x4
  and get nothing. Selling something that has no effect for that buyer is misleading (Terms of Use /
  Experience Guidelines on deceptive or misleading purchases). **Required fix:** the shop hides or
  disables purchase buttons for every tier at or below the player's highest owned tier, and each pass
  description says: "Your earnings become xN. Does not stack with other Candy passes; the highest one
  you own applies." The in-game shop says the same next to every tier.
- **Framing:** never call the ladder "pay to win", "beat everyone" or similar in UI or ads; use neutral
  wording ("earn Cash faster"). No fake urgency: no countdown timers, "limited time" or fake discounts
  on the ladder (manipulative-design concerns, target audience 9-14).
- **Donations (5 to 1,000 R$):** description is honest ("support the developer, no in-game advantage")
  and the cosmetic rewards are listed. PASS, with conditions: (a) never imply money goes to charity or
  a cause; (b) each product description lists exactly its reward, including "for this session" on the
  Huge sparkle; (c) rewards must be delivered exactly as described, nothing extra promised (e.g. no
  "secret perks" teasers).
- **Top Donors board: RISK.** A public ranking of R$ spent can pressure a 9-14 audience into competitive
  spending. **Recommended safe option:** show names and rank only, never Robux amounts, and let players
  opt out (see item 5). Owner decision (monetization change -> human gate).
- **Leaderboard dominance by pass owners (GDD Q3):** not a policy issue; product decision only.

### 3. Maturity and content label: PASS
Likely questionnaire answers: violence none; blood none; crude humor none; fear none; romance none;
alcohol/drugs/tobacco none; gambling none (no random items, no betting); strong language none;
free-form user creation none; social hangout no; paid random items no. **Likely label: Minimal.**
Action at `/launch`: the owner must complete the Experience Guidelines / maturity questionnaire before
publishing; unrated experiences have reduced visibility and access (exact current restriction not
verified). Candy art must not use alcohol-filled sweets (e.g. liqueur chocolates).

### 4. IP / trademark: PASS (low risk)
- "Candy Factory Tycoon" is descriptive and generic (common words, common Roblox genre suffix). Generic
  names are weak trademarks and low infringement risk, but also hard to protect and may collide with
  existing Roblox games of the same name. Recommendation: search Roblox for exact matches before launch;
  a more distinctive name helps discovery (GDD Q6, marketer's call).
- Avoid famous candy/entertainment marks in names, models, decals and ads: Candy Crush, Candy Land,
  Wonka / Willy Wonka / "golden ticket", Sugar Rush (Wreck-It Ralph), Skittles, M&M's, Kit Kat,
  Hershey's, Jolly Rancher, Haribo gold bear shapes. Dropper names in the GDD are all generic. PASS.
- Genre study names (Miner's Haven, Retail Tycoon 2, etc.) are mechanics references only; never copy
  their assets, UI layouts, logos or names. Re-check at `/launch` against asset-log.md.

### 5. Privacy: RISK
- No personal info collected; no text input; leaderboards use UserId and Roblox display names only. PASS.
- Analytics: none specified yet. Rule for architecture: only UserId-keyed gameplay events, no PII, no
  free text. Re-check when docs/architecture.md lists analytics fields.
- If any text input is added later (plot names, codes are fine), filter via TextService before display.
- **Top Donors board publishes how much Robux a (likely minor) user spent. RISK.** Fix as in item 2:
  rank without amounts, plus an opt-out setting saved in DataStore. Server-wide thank-you message
  names the donor; acceptable, but respect the same opt-out.

### 6. DevEx (owner notes, not a decision): PASS
Eligibility as last known (not verified against current DevEx Terms): owner 13+ (parental consent if a
minor), verified email, account in good standing with no ToS violations, minimum earned Robux balance
(historically 30,000 earned R$), a valid DevEx portal account and tax forms. Only Robux earned through
the game count. Note: at 4-32 R$ prices, reaching the minimum needs high volume.

### 7. Advertising: PASS (nothing to review yet)
No ad creatives exist. When marketer drafts ads: follow Roblox Advertising Standards (no misleading
claims, no implied free Robux, no "pay to win" framing, no references to other games/brands, no
off-platform links, age-appropriate content). Re-run this item at `/launch`.
