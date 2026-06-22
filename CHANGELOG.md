# Changelog

## 1.5

### Added

- **Consumable tracking** — Track flasks, potions, food, runes, oils, drums, and more. Counts are quality-tier-aware, summing both crafted quality tiers into a single total.
- **Consumables manager window** — Open it via `/rcl` or the options panel to add, remove, and set a per-item low-supply threshold.
- **Consumables on the ready-check window** — Tracked consumables now appear when a ready check fires, with low/missing highlighting.
- **Quick-add search bar** — Find items from your bags or the catalog from a single search box, without scrolling the Add dropdowns.
- **Account-wide consumable profiles** — Set your list up on one character and bring it to another with "Copy from", then adjust it per character.

### Changed

- Updated for patch 12.0.7.

## 1.4

### Added

- **Gear durability display** — The ready check window now shows average gear durability
  with the single lowest-durability item called out alongside, color-coded green (>75%),
  yellow (>25%), or red (≤25%). Iterates the eleven durability-bearing equipment slots
  (head, shoulder, chest, waist, legs, feet, wrist, hands, back, main hand, off hand) via
  `GetInventoryItemDurability` and computes both the weighted average and the per-item minimum.
  Enabled by default; toggleable via `/rcl` → "Show Gear Durability". Optional chat
  announcement available via "Output Gear Durability in chat" (off by default).

- **Live durability refresh** — The durability label updates while the ready check window
  is open. `UPDATE_INVENTORY_DURABILITY` catches damage and repairs;
  `PLAYER_EQUIPMENT_CHANGED` catches mid-ready-check gear swaps. The latter is filtered
  against the durability-bearing slot set, so trinket/ring/neck/shirt/tabard changes don't
  trigger redundant rebuilds. The handler is gated on `frame:IsShown()` and
  `settings.showDurability` so it does no work when irrelevant.

- **Output channel selector** — All chat announcements (talents, runes, durability) now route
  through a single configurable channel via a dropdown in options. Options are `/say`, `/yell`,
  `/party`, `/raid`, `/instance`, `/emote`, and "Smart (auto)" — the smart mode picks the most
  appropriate group channel based on context (`INSTANCE_CHAT` → `RAID` → `PARTY` → `SAY` fallback).
  Default is `/say`, preserving prior behavior for existing users. All output flows through a
  single `Announce()` helper that strips color codes and resolves the active channel at send time.

- **Frame appearance controls** — Scale slider (0.5×–2.0×), opacity slider (10–100%), and a
  lock-frame toggle to prevent accidental drags. Window position is now persisted across sessions
  via a new `framePoint` saved variable, applied at `ADDON_LOADED`. A "Reset Position" button
  recenters the window if it ends up off-screen. Both the main window and options panel use
  `SetClampedToScreen` so scaling can't push them out of view.

- **Options panel reorganization** — Reworked into a two-column 580×480 layout with four
  section headers: Display and Announcements in the left column, Auto-Switch and Frame
  Appearance in the right. The previous single-column layout was too tall to fit comfortably
  on smaller resolutions once the new controls were added.

### Changed

- **DK rune chat output** now routes through the configurable output channel (previously
  hardcoded to `/say`). Behavior is preserved for users who keep the channel at its default.

- **`/rcldebug`** now also prints the resolved output channel, current frame scale, opacity,
  and lock state alongside the existing talent/preset state.

## 1.3

### Added

- **Loot Specialization display** — The ready check window now shows the player's active loot
  specialization. Uses `GetLootSpecialization()`: if the value is `0` (meaning loot spec is set
  to follow the active spec), it displays `"Active Spec"`; otherwise it resolves the spec name
  via `GetSpecializationInfoByID()`. Enabled by default; can be toggled via `/rcl` →
  "Show Loot Specialization".

### Fixed

- **DK rune false "Missing!" on ready check** — Death Knight weapon runes (applied via runeforging)
  are permanent weapon enchants. The previous code used `GetWeaponEnchantInfo()` as a boolean
  gate before calling `GetWeaponEnchantText()`, but `GetWeaponEnchantInfo()` only reports
  *temporary* enchants (oils, sharpening stones, shaman imbues, etc.) and always returns `false`
  for runeforge enchants. This caused the rune row to display "|cffff0000Missing!|r" even when a
  rune such as Rune of the Fallen Crusader or Rune of Razorice was correctly equipped.

  **Root cause:** `hasMH` / `hasOH` from `GetWeaponEnchantInfo()` were used to decide whether to
  call `GetWeaponEnchantText()`, which itself scans tooltip data for
  `Enum.TooltipDataLineType.ItemEnchantmentPermanent` lines — the correct line type for runeforges.
  The boolean gate short-circuited before the correct check ever ran.

  **Fix:** Removed `GetWeaponEnchantInfo()` from the DK rune detection path entirely.
  `GetWeaponEnchantText()` now returns `nil` instead of `"Other Enchant"` when no permanent
  enchant is found, and its return value is used directly as both the presence check and the
  display name. Runes are shown correctly; missing runes still display the red "Missing!" label.

## 1.0.0

- Initial release
