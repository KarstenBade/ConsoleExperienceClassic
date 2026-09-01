# This fork

ConsoleExperienceClassic, maintained for the **World of Fiedel** realm (bade.dev) and shipped
through its launcher, where it is the gamepad UI for Steam Deck players. Kept as a fork so
Deck-specific changes are ordinary commits instead of unified diffs carried against a
164 KB `config/config.lua` and a 105 KB `actionbars/bars.lua` — diffs that size stop applying
on the first upstream release, and a patch that no longer applies blocks every sync.

## Lineage

- `pepordev/ConsoleExperienceClassic` — upstream, at
  `c2f2dfc555ff4bc2ec625281e813b4eb7a080aa0` (v0.17.3, 2026-03-10) when this fork's work began.
- `upstream-main` here is pinned at exactly that commit and never moves except to follow
  upstream, so **`git diff upstream-main..main` is our entire delta**.

Upstream carries no LICENSE, so this is formally all-rights-reserved and is redistributed on
that understanding, unchanged from how the addon already reached players. Authorship and
copyright remain with pepordev.

Upstream tracks versions with release-please; the `## Version:` line in the toc is CI-managed
there and is ours to maintain here.

## Changes

**Game menu button stacking.** ShaguTweaks and this addon both added an Escape-menu entry by
anchoring to `GameMenuButtonUIOptions`' bottom and re-anchoring `GameMenuButtonKeybindings`
below themselves — so with both installed the two buttons landed on the same spot and drew on
top of each other. Both now anchor below whatever already sits above Keybindings, which is
unchanged behaviour alone and stacks correctly together.

**This fix is one half of a pair.** The other half is a patch against ShaguTweaks carried in
`wow_server_development/distribution/addons/patches/ShaguTweaks-game-menu-stacking.patch`.
They are order-independent by construction (each asks where Keybindings currently is), so
neither depends on the other loading first — but if an upstream merge ever conflicts around
`Config:CreateGameMenuButton`, that patch is the context you need. Offered upstream as a PR.

## Not here: the `actionSlotBase` / `/ceslots` experiment

A World of Fiedel release briefly let this addon's four pages and side bars be
shifted into a different range of action slots, so a gamepad device and a
desktop could use disjoint slots on the same character. It was carried as a
downstream patch, never as a commit here, and it is withdrawn: with up to 12
bars of 10 buttons in use on a desktop there is no free range to shift into.
Per-device action bar profiles in SimpleActionSets are the replacement.

It reached only the realm's own PTR and nobody enabled it, so there is no
migration and no leftover setting to clean up. Mentioned only so the idea is
not reinvented.

## How it ships

Vendored by sha, not by branch, from
`wow_server_development/distribution/addons/sources.toml`, materialised by `addons/sync.py`.
`docs/` (7 MB of an 8.2 MB repo, referenced by nothing) and the release-please plumbing are
excluded there rather than deleted here, so this tree stays a clean diff against upstream.

Note for anyone tempted: the addon refers to its own folder name in 53 places and its saved
variables are `ConsoleExperienceDB`, so the installed folder must stay
`ConsoleExperienceClassic`.
