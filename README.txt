KH1FM Equipment Stats, Abilities, LIMIT and RISK v2
===================================================

This package contains one gameplay Lua. It replaces both:

  ZZZ_KH1FM_Equipment_Bonus_Controller_v1_1.lua
  ZZZ_KH1FM_LIMIT_System_v1_6_EnemyBoundsOrder.lua

Keep these compatible companions enabled:

  ZZZ_KH1FM_Smooth_Circular_HP_Custom_MP_LIMIT_HUD_v1_7.lua
  KHFM_EnemyConfig_v4_4_31_LIMITOrder.lua

Edit KEYBLADES and ACCESSORIES near the top of the Lua. Every row supports:

  HP, MP, STR, DEF,
  FIRE_RESISTANCE, ICE_RESISTANCE,
  LIGHTNING_RESISTANCE, DARK_RESISTANCE,
  LIMIT, RISK, ABILITIES

Resistance fields use percentage points. +20 means 20% less elemental damage;
-20 means 20% more.

LIMIT changes the base +10 block/parry/deflect event:

  LIMIT = 5     generates 15
  LIMIT = -10   generates 0
  LIMIT = -15   removes 5

RISK changes the base 5 points lost on a damaging hit:

  RISK = 3      loses 8
  RISK = -3     loses 2
  RISK = -5     loses 0
  RISK = -8     gains 3

Abilities are granted only while at least one granting item remains equipped.
An ability Sora already owns is never claimed or removed by this script.

Install/upgrade:

  1. Disable the two replaced Lua files listed above.
  2. Install this package.
  3. Fully close KH1FM.
  4. Use OpenKH Build and Run; do not use F1 for the first launch.

Expected console prefix:

  [EquipmentLimitRiskV2]

To uninstall safely, set CONFIG.ENABLE=false, press F1 once while a save is
loaded, save the game, then remove the Lua.
