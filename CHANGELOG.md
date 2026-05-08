# Changelog

## 1.0.1

### Added

- **Loot Specialization display** — The ready check window now shows the player's active loot
  specialization. Uses `GetLootSpecialization()`: if the value is `0` (meaning loot spec is set
  to follow the active spec), it displays `"Active Spec"`; otherwise it resolves the spec name
  via `GetSpecializationInfoByID()`. Enabled by default; can be toggled via `/rcl` →
  "Show Loot Specialization".

## Unreleased

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
