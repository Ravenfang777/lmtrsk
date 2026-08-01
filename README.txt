KH1FM Equipment Stats, Abilities, LIMIT and RISK v2.3
=====================================================

This package contains one gameplay Lua. It replaces:

  ZZZZ_KH1FM_Equipment_Stats_Abilities_LIMIT_RISK_v2_2.lua
  ZZZZ_KH1FM_Equipment_Stats_Abilities_LIMIT_RISK_v2.lua
  ZZZZ_KH1FM_Equipment_Stats_Abilities_LIMIT_RISK_v2_1.lua
  ZZZ_KH1FM_Equipment_Bonus_Controller_v1_1.lua
  ZZZ_KH1FM_LIMIT_System_v1_6_EnemyBoundsOrder.lua

Keep these compatible companions enabled:

  ZZZ_KH1FM_Smooth_Circular_HP_Custom_MP_LIMIT_HUD_v1_7.lua
  KHFM_EnemyConfig_v4_4_31_LIMITOrder.lua

V2.3 loader correction
----------------------

The submitted v2.2 configuration could not be initialized by LuaEngine:

  line 210: unexpected symbol near '+'

The Oathkeeper row used ICE_RESISTANCE=+100, which Lua 5.x does not accept,
and was also missing the comma before ABILITIES. Because this was a syntax
error, none of the controller ran. V2.3 uses ICE_RESISTANCE=100 and preserves
the intended signed Oathkeeper settings. Positive table values must be written
without a leading plus sign; negative values continue to use '-'.

Preserved v2.2 stat correction
------------------------------

V2.1 always subtracted its previously owned HP/MP/STR/DEF delta before
reapplying the configured bonus. When KH1 had already rebuilt Sora's character
page to native values, that subtraction cancelled the bonus instead.

V2.2 distinguishes these two cases:

  * Current value still equals the script's expected value:
      remove the old owned delta, then apply the current equipment table.

  * Current value differs because KH1 refreshed the character page:
      accept the current value as the new baseline, then apply the current
      equipment table without subtracting the old delta again.

Impossible v2/v2.1 state ledgers are rejected automatically. If an older
ledger is mathematically plausible but was already left in the cancelled
state, unequip and re-equip the configured Keyblade once after v2.3 reports
READY. That native equipment refresh lets v2.3 rebuild the correct baseline.

Preserved Oathkeeper test row
-----------------------------

  HP=100, MP=20, STR=4, DEF=1,
  ICE_RESISTANCE=100, LIMIT=-15, RISK=-15,
  ABILITIES={ "MP Haste" }

The raw MP Haste ID 0x17 remains the active form used by the separate MP
Haste/Rage controller. V2.3 keeps the v2.1 ability ownership/migration logic.

All editable rows support:

  HP, MP, STR, DEF,
  FIRE_RESISTANCE, ICE_RESISTANCE,
  LIGHTNING_RESISTANCE, DARK_RESISTANCE,
  LIMIT, RISK, ABILITIES

Install/upgrade
---------------

  1. Disable v2.2, v2.1, v2, Equipment Bonus v1.1, and standalone LIMIT v1.6.
  2. Install this package.
  3. Do not delete KH1FM_Equipment_Stats_Abilities_LIMIT_RISK_v2_State.txt.
  4. Fully close KH1FM.
  5. Use OpenKH Build and Run; do not use F1 for the first launch.
  6. With the save loaded, unequip and re-equip Oathkeeper once for a clean
     v2.1-cancelled-state repair test.

Expected console prefix:

  [EquipmentLimitRiskV2.3]

Expected Oathkeeper lines include:

  EQUIPMENT: Oathkeeper
  CUSTOM BONUS: HP=100 MP=20 STR=4 DEF=1

To uninstall safely, set CONFIG.ENABLE=false, press F1 once while a save is
loaded, save the game, then remove the Lua.
