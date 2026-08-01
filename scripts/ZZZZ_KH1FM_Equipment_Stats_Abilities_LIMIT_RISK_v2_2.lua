LUAGUI_NAME = "KH1FM Equipment Stats, Abilities, LIMIT and RISK v2.2"
LUAGUI_AUTH = "OpenAI"
LUAGUI_DESC = "One reversible Keyblade/accessory controller integrated with LIMIT v1.6."

--[[
    KH1FM EQUIPMENT STATS, ABILITIES, LIMIT AND RISK v2.2
    Target: KINGDOM HEARTS FINAL MIX.exe, Steam Global 1.0.0.2
    SHA-256: d790746245d26159f3ee0e1060e33b2fa2de06941850a4ac724f598722884bac
    Runtime: LuaBackendHook v1.9.1-hook / LuaEngine v5.0

    IMPLEMENTED RULES
      * LIMIT is clamped to 0..100.
      * A confirmed Sora parry-reaction entry (animation 0x6E or 0x6F) grants
        10 base LIMIT plus the current equipment restoration modifier. This
        covers ordinary melee blocks that v1 missed.
      * Native Tech paths are projectile candidates, not direct LIMIT awards.
        A candidate grants the same restoration only when it does not coincide
        with Sora taking damage. It is deduplicated against a parry reaction
        from the same contact.
      * Native Tech EXP and the Tech popup remain suppressed. Enemy-defeat EXP
        and its EXP popup use separate native paths and remain untouched.
      * If LIMIT is positive before Sora receives a negative finalized HP delta,
        that delta is reduced by 20% and LIMIT is reduced by 5 base points plus
        the current equipment loss modifier immediately.
      * Integer damage rounds the remaining 80% upward and preserves KH1's
        one-damage minimum:
            1 -> 1, 2 -> 2, 3 -> 3, 4 -> 4, 5 -> 4, 10 -> 8.
      * Every equipped Keyblade/accessory row can add signed HP, MP, STR, DEF,
        Fire/Ice/Lightning/Dark resistance, temporary Sora abilities, LIMIT,
        and RISK. Repeated accessories count once per equipped copy.
      * KH1FM ability bytes use the low seven bits for the ability ID and the
        high bit as the UNEQUIPPED flag. Equipment-granted abilities are
        therefore written as their raw ID (for example, MP Haste is 0x17),
        never ID+0x80 (MP Haste 0x97, present but unequipped).
      * A v2 ownership ledger is migrated in place. Any ability v2 left in its
        unequipped state is activated without stacking stats or losing the
        byte that must be restored when the granting gear is removed.
      * Native character-page refreshes are distinguished from values still
        owned by this script. If KH1 rebuilds HP/MP/STR/DEF, the rebuilt values
        become the new baseline and the configured equipment bonuses are
        reapplied instead of being accidentally cancelled.
      * Impossible v2/v2.1 ledgers (for example, expected MP minus the recorded
        owned bonus being negative) are rejected and repaired from the live
        character page on the first v2.2 update.
      * LIMIT changes the +10 confirmed block/parry/deflect event. Values below
        -10 make the defensive event remove LIMIT instead of generating it.
      * RISK changes the base 5 LIMIT lost on damage. Values below -5 invert the
        event, causing damage to generate LIMIT instead of removing it.
      * LIMIT is persisted in a small state file beside this Lua. Runtime
        changes are coalesced and written no more than once per configured
        interval; pointer transitions force-flush any pending value.
      * Sora's outgoing attack damage gains one 20% tier for every full
        20 LIMIT:
             0..19 = 100%, 20..39 = 120%, 40..59 = 140%,
            60..79 = 160%, 80..99 = 180%,     100 = 200%.
        Partial points never provide a partial tier.
        This applies to the shared native attack/spell formula used by Sora's
        melee hits, magic, abilities, and Sora-owned projectiles. Party-member
        and enemy damage are not scaled.

    DAMAGE ORDER
      Outgoing enemy damage:
        native attack/spell formula
        -> KHFM_EnemyConfig DAMAGE_TAKEN
        -> LIMIT outgoing tier
        -> KHFM_EnemyConfig DAMAGE_FLOOR/DAMAGE_CEILING
        -> HP subtraction

      Incoming Sora damage:
        native finalized damage
        -> KHFM_EnemyConfig enemy-damage multiplier
        -> LIMIT 20% protection
        -> any later damage floor/ceiling
        -> HP subtraction

      V1.6 marks only Sora-owned hits at the shared attack/spell formula.
      KHFM_EnemyConfig v4.4.31 consumes that one-hit marker after its enemy
      multiplier and before its floor/ceiling. This removes v1.5's intermediate
      integer rounding and keeps party-member damage unscaled.

    COMPATIBILITY
      * Companion build: KHFM_EnemyConfig v4.4.31 LIMIT Order.
      * The companion owns its normal damage call/cave and changes only the
        verified multiplier-to-clamp tail while this interface is live.
      * Does not touch NumericHudV1.9's private region or its HUD patches.
      * Owns only its reversible HP/MP/STR/DEF deltas, four live resistance
        deltas, and temporary ability entries. Inventory and EXP are untouched.
      * LIMIT lives only in this script's private runtime region and sidecar.

    CURRENT SCOPE
      This build implements confirmed block/deflection acquisition, Tech
      replacement, 20% incoming-damage protection, equipment-controlled signed
      LIMIT/RISK events, reversible stats/resistances/abilities, persistence,
      and Sora outgoing-damage tiers.
      The custom LIMIT gauge remains separate.

    SAFETY
      * Every native function and patch site requires an exact Steam Global
        signature.
      * A fresh install requires an empty private region.
      * F1 reload recognizes this script and the exact v1.5 outgoing wrapper.
      * Unknown or partial hooks are refused.
      * Set CONFIG.ENABLE=false and press F1 once to restore every owned byte.

    STABILIZATION
      * Combat event and outgoing-damage logs are quiet by default.
      * Set CONFIG.DEBUG_MODE=true to restore the detailed v1.4 diagnostics.
      * A compact activity summary is emitted at most once per configured
        interval.
      * The confirmed block and incoming-protection machine code is unchanged
        from v1.5; only outgoing ordering and tier size changed.
]]

local CONFIG = {
    ENABLE = true,

    PERSIST_BETWEEN_SESSIONS = true,
    STARTING_LIMIT_WITHOUT_STATE = 0,
    STATE_FILENAME = "KH1FM_LIMIT_System_v1_State.txt",
    PERSISTENCE_WRITE_INTERVAL_SECONDS = 1.0,
    FORCE_SAVE_ON_SORA_POINTER_CHANGE = true,

    DEBUG_MODE = false,
    LOG_EACH_EVENT = true,
    LOG_OUTGOING_DAMAGE = false,
    LOG_PERIODIC_SUMMARY = true,
    SUMMARY_INTERVAL_SECONDS = 10.0,
    TECH_CANDIDATE_DAMAGE_WINDOW_FRAMES = 1,

    -- Optional global signed offsets applied in addition to every equipped
    -- row. Examples: -2 RISK makes a hit cost 3; +5 LIMIT makes a confirmed
    -- block restore 15.
    INITIAL_EQUIPMENT_RESTORE_MODIFIER = 0,
    INITIAL_EQUIPMENT_LOSS_MODIFIER = 0,
    UPDATE_EQUIPMENT_EVERY_N_FRAMES = 10,
    LOG_EQUIPMENT_CHANGES = true,

    PRESERVE_MISSING_HP = true,
    PRESERVE_MISSING_MP = true,
    LOG_ABILITY_CHANGES = true,
    EQUIPMENT_STATE_FILENAME =
        "KH1FM_Equipment_Stats_Abilities_LIMIT_RISK_v2_State.txt",
    LEGACY_EQUIPMENT_STATE_FILENAME =
        "KH1FM_Equipment_Bonus_Controller_v1_1_State.txt",
}

--[[
    EDITABLE EQUIPMENT TABLES

    All numeric fields are signed and every equipped copy is counted.

      HP / MP / STR / DEF
          Direct additions to Sora's corresponding stat byte (final 0..255;
          Max HP remains at least 1).

      FIRE_RESISTANCE / ICE_RESISTANCE / LIGHTNING_RESISTANCE / DARK_RESISTANCE
          Percentage points of resistance. +20 means 20% less damage of that
          element; -20 means 20% more. These are live reversible modifiers and
          do not overwrite the native accessory definitions.

      LIMIT
          Added to the base +10 confirmed block/parry/deflect event.
          Example: LIMIT=-15 makes the event remove 5 LIMIT.

      RISK
          Added to the base 5 LIMIT lost when Sora takes damage.
          Example: RISK=-3 loses 2; RISK=-5 loses 0; RISK=-8 gains 3.

      ABILITIES
          Names from SORA_ABILITY_IDS below. The entry is equipped while at
          least one granting item remains and is removed automatically when the
          final granting Keyblade/accessory is unequipped.

    Add ENABLED=false to any row you want the controller to ignore.
]]

local function GEAR(row)
    row.ENABLED = row.ENABLED ~= false
    row.HP = row.HP or 0
    row.MP = row.MP or 0
    row.STR = row.STR or 0
    row.DEF = row.DEF or 0
    row.FIRE_RESISTANCE = row.FIRE_RESISTANCE or 0
    row.ICE_RESISTANCE = row.ICE_RESISTANCE or 0
    row.LIGHTNING_RESISTANCE = row.LIGHTNING_RESISTANCE or 0
    row.DARK_RESISTANCE = row.DARK_RESISTANCE or 0
    row.LIMIT = row.LIMIT or 0
    row.RISK = row.RISK or 0
    row.ABILITIES = row.ABILITIES or {}
    return row
end

local KEYBLADES = {
    ["Kingdom Key"]      = GEAR({}),
    ["Dream Sword"]      = GEAR({}),
    ["Dream Shield (Sora)"] = GEAR({}),
    ["Dream Rod (Sora)"] = GEAR({}),
    ["Wooden Sword"]     = GEAR({}),
    ["Jungle King"]      = GEAR({}),
    ["Three Wishes"]     = GEAR({}),
    ["Fairy Harp"]       = GEAR({}),
    ["Pumpkinhead"]      = GEAR({}),
    ["Crabclaw"]         = GEAR({}),
    ["Divine Rose"]      = GEAR({}),
    ["Spellbinder"]      = GEAR({}),
    ["Olympia"]          = GEAR({}),
    ["Lionheart"]        = GEAR({}),
    ["Metal Chocobo"]    = GEAR({}),
    ["Oathkeeper"] = GEAR({
        HP = 15, MP = 5, STR = 5, DEF = 5, ICE_RESISTANCE =+100, LIMIT =+20, RISK=+40
        ABILITIES = { "MP Haste" },
    }),
    ["Oblivion"]         = GEAR({}),
    ["Lady Luck"]        = GEAR({}),
    ["Wishing Star"]     = GEAR({}),
    ["Ultima Weapon"]    = GEAR({}),
    ["Diamond Dust"]     = GEAR({}),
    ["One-Winged Angel"] = GEAR({}),
}

local ACCESSORIES = {
    ["Protect Chain"] = GEAR({}),
    ["Protera Chain"] = GEAR({}),
    ["Protega Chain"] = GEAR({}),
    ["Fire Ring"] = GEAR({}),
    ["Fira Ring"] = GEAR({}),
    ["Firaga Ring"] = GEAR({}),
    ["Blizzard Ring"] = GEAR({}),
    ["Blizzara Ring"] = GEAR({}),
    ["Blizzaga Ring"] = GEAR({}),
    ["Thunder Ring"] = GEAR({}),
    ["Thundara Ring"] = GEAR({}),
    ["Thundaga Ring"] = GEAR({}),
    ["Ability Stud"] = GEAR({}),
    ["Guard Earring"] = GEAR({}),
    ["Master Earring"] = GEAR({}),
    ["Chaos Ring"] = GEAR({}),
    ["Dark Ring"] = GEAR({}),
    ["Element Ring"] = GEAR({}),
    ["Three Stars"] = GEAR({}),
    ["Power Chain"] = GEAR({}),
    ["Golem Chain"] = GEAR({}),
    ["Titan Chain"] = GEAR({}),
    ["Energy Bangle"] = GEAR({}),
    ["Angel Bangle"] = GEAR({}),
    ["Gaia Bangle"] = GEAR({}),
    ["Magic Armlet"] = GEAR({}),
    ["Rune Armlet"] = GEAR({}),
    ["Atlas Armlet"] = GEAR({}),
    ["Heartguard"] = GEAR({}),
    ["Ribbon"] = GEAR({}),
    ["Crystal Crown"] = GEAR({ ENABLED = false }),
    ["Brave Warrior"] = GEAR({}),
    ["Ifrit's Horn"] = GEAR({}),
    ["Inferno Band"] = GEAR({}),
    ["White Fang"] = GEAR({}),
    ["Ray of Light"] = GEAR({}),
    ["Holy Circlet"] = GEAR({}),
    ["Raven's Claw"] = GEAR({}),
    ["Omega Arts"] = GEAR({}),
    ["EXP Earring"] = GEAR({}),
    ["EXP Ring"] = GEAR({}),
    ["EXP Bracelet"] = GEAR({}),
    ["EXP Necklace"] = GEAR({}),
    ["Firagun Band"] = GEAR({}),
    ["Blizzagun Band"] = GEAR({}),
    ["Thundagun Band"] = GEAR({}),
    ["Ifrit Belt"] = GEAR({}),
    ["Shiva Belt"] = GEAR({}),
    ["Ramuh Belt"] = GEAR({}),
    ["Moogle Badge"] = GEAR({}),
    ["Cosmic Arts"] = GEAR({}),
    ["Royal Crown"] = GEAR({}),
    ["Prime Cap"] = GEAR({}),
    ["Obsidian Ring"] = GEAR({}),
}

local PREFIX = "[EquipmentLimitRiskV2.2] "
local MAX_LIMIT = 100
local LIMIT_RESTORE_BASE = 10
local LIMIT_LOSS_PER_HIT_BASE = 5
local LIMIT_POINTS_PER_DAMAGE_TIER = 20
local LIMIT_DAMAGE_BONUS_PERCENT_PER_TIER = 20
local LIMIT_MAX_DAMAGE_TIERS = 5

local VERSION_SENTINEL_RVA = 0x3B2271
local VERSION_VALUE = 0x7265737563697065

local SORA_CHARACTER_BASE_RVA = 0x2DE9364
local SORA_POINTER_RVA = 0x2537E48
local SORA_CURRENT_ANIMATION_OFFSET = 0x164
local SORA_ANIMATION_TIME_OFFSET = 0x16C
local SORA_ACCESSORY_COUNT_OFFSET = 0x18
local SORA_ACCESSORY_FIRST_OFFSET = 0x19
local SORA_WEAPON_OFFSET = 0x32
local SORA_ACCESSORY_SLOT_CAPACITY = 8

local PARRY_ANIMATIONS = {
    [0x6E] = "Parry reaction 1",
    [0x6F] = "Parry reaction 2",
}

-- Live Steam Global Sora data used by the proven equipment controller and
-- KHPCSpeedrunTools' six-float Sora resistance array. The resistance ordering
-- is Physical, Fire, Blizzard/Ice, Thunder/Lightning, Dark, Special.
local SORA_RESISTANCE_RVA = 0x2D5CB88
local CHARACTER_OFFSET = {
    LEVEL = 0x00,
    CURRENT_HP = 0x01,
    MAX_HP = 0x02,
    CURRENT_MP = 0x03,
    MAX_MP = 0x04,
    STRENGTH = 0x06,
    DEFENSE = 0x07,
    ACCESSORY_COUNT = 0x18,
    ACCESSORIES = 0x19,
    WEAPON = 0x32,
    EXPERIENCE = 0x3C,
    ABILITIES = 0x40,
}
local RESISTANCE_OFFSET = {
    fire = 0x04,
    ice = 0x08,
    lightning = 0x0C,
    dark = 0x10,
}
local ABILITY_SLOT_CAPACITY = 0x30

local EQUIPMENT_NAMES = {
    [0x11] = "Protect Chain", [0x12] = "Protera Chain",
    [0x13] = "Protega Chain", [0x14] = "Fire Ring",
    [0x15] = "Fira Ring", [0x16] = "Firaga Ring",
    [0x17] = "Blizzard Ring", [0x18] = "Blizzara Ring",
    [0x19] = "Blizzaga Ring", [0x1A] = "Thunder Ring",
    [0x1B] = "Thundara Ring", [0x1C] = "Thundaga Ring",
    [0x1D] = "Ability Stud", [0x1E] = "Guard Earring",
    [0x1F] = "Master Earring", [0x20] = "Chaos Ring",
    [0x21] = "Dark Ring", [0x22] = "Element Ring",
    [0x23] = "Three Stars", [0x24] = "Power Chain",
    [0x25] = "Golem Chain", [0x26] = "Titan Chain",
    [0x27] = "Energy Bangle", [0x28] = "Angel Bangle",
    [0x29] = "Gaia Bangle", [0x2A] = "Magic Armlet",
    [0x2B] = "Rune Armlet", [0x2C] = "Atlas Armlet",
    [0x2D] = "Heartguard", [0x2E] = "Ribbon",
    [0x2F] = "Crystal Crown", [0x30] = "Brave Warrior",
    [0x31] = "Ifrit's Horn", [0x32] = "Inferno Band",
    [0x33] = "White Fang", [0x34] = "Ray of Light",
    [0x35] = "Holy Circlet", [0x36] = "Raven's Claw",
    [0x37] = "Omega Arts", [0x38] = "EXP Earring",
    [0x3A] = "EXP Ring", [0x3B] = "EXP Bracelet",
    [0x3C] = "EXP Necklace", [0x3D] = "Firagun Band",
    [0x3E] = "Blizzagun Band", [0x3F] = "Thundagun Band",
    [0x40] = "Ifrit Belt", [0x41] = "Shiva Belt",
    [0x42] = "Ramuh Belt", [0x43] = "Moogle Badge",
    [0x44] = "Cosmic Arts", [0x45] = "Royal Crown",
    [0x46] = "Prime Cap", [0x47] = "Obsidian Ring",

    [0x51] = "Kingdom Key", [0x52] = "Dream Sword",
    [0x53] = "Dream Shield (Sora)", [0x54] = "Dream Rod (Sora)",
    [0x55] = "Wooden Sword", [0x56] = "Jungle King",
    [0x57] = "Three Wishes", [0x58] = "Fairy Harp",
    [0x59] = "Pumpkinhead", [0x5A] = "Crabclaw",
    [0x5B] = "Divine Rose", [0x5C] = "Spellbinder",
    [0x5D] = "Olympia", [0x5E] = "Lionheart",
    [0x5F] = "Metal Chocobo", [0x60] = "Oathkeeper",
    [0x61] = "Oblivion", [0x62] = "Lady Luck",
    [0x63] = "Wishing Star", [0x64] = "Ultima Weapon",
    [0x65] = "Diamond Dust", [0x66] = "One-Winged Angel",
}

local SORA_ABILITY_IDS = {
    ["Treasure Magnet"] = 0x05,
    ["Combo Plus"] = 0x06,
    ["Air Combo Plus"] = 0x07,
    ["Critical Plus"] = 0x08,
    ["Second Wind"] = 0x09,
    ["Scan"] = 0x0A,
    ["Sonic Blade"] = 0x0B,
    ["Ars Arcanum"] = 0x0C,
    ["Strike Raid"] = 0x0D,
    ["Ragnarok"] = 0x0E,
    ["Trinity Limit"] = 0x0F,
    ["Cheer"] = 0x10,
    ["Vortex"] = 0x11,
    ["Aerial Sweep"] = 0x12,
    ["Counterattack"] = 0x13,
    ["Blitz"] = 0x14,
    ["Guard"] = 0x15,
    ["Dodge Roll"] = 0x16,
    ["MP Haste"] = 0x17,
    ["MP Rage"] = 0x18,
    ["Second Chance"] = 0x19,
    ["Berserk"] = 0x1A,
    ["Jackpot"] = 0x1B,
    ["Lucky Strike"] = 0x1C,
    ["Slapshot"] = 0x35,
    ["Sliding Dash"] = 0x36,
    ["Hurricane Blast"] = 0x37,
    ["Ripple Drive"] = 0x38,
    ["Stun Impact"] = 0x39,
    ["Gravity Break"] = 0x3A,
    ["Zantetsuken"] = 0x3B,
    ["Tech Boost"] = 0x3C,
    ["Encounter Plus"] = 0x3D,
    ["Leaf Bracer"] = 0x3E,
    ["EXP Zero"] = 0x40,
    ["Combo Master"] = 0x41,
}

local NAME_TO_EQUIPMENT_ID = {}
local NORMALIZED_ABILITY_IDS = {}
local ABILITY_NAMES_BY_ID = {}
local COMPILED_GEAR_BY_ID = {}

local POINTER_RESOLVER_RVA = 0x38ADC0
local FINAL_HP_ADJUST_RVA = 0x2A4920
local DAMAGE_FORMULA_RVA = 0x2BFA80

-- The shared attack/spell calculation call. At this point RCX is the attack
-- context, RDX is the target object, and EAX receives the native damage after
-- the target's stock floor/cap and resistance calculations.
local DAMAGE_FORMULA_CALL_RVA = 0x2BF94F
local DAMAGE_FORMULA_CALL_ORIGINAL = {
    0xE8, 0x2C, 0x01, 0x00, 0x00,
}

-- KHFM_EnemyConfig owns +0x2A4930. This script deliberately leaves it alone.
local ENEMY_CONFIG_HOOK_RVA = 0x2A4930
local ENEMY_CONFIG_NATIVE_BYTES = {
    0x48, 0x8B, 0xF1, 0x44, 0x8B, 0xF2,
}
local ENEMY_CONFIG_V2_BYTES = {
    0xE8, 0x1B, 0xA8, 0x10, 0x00, 0x90,
}

-- The following eight bytes normally load the encoded stat-page reference and
-- call KH1's resolver. The replacement calls this script's finalizer; that
-- finalizer applies LIMIT rules, replays the load, and tail-jumps to the same
-- resolver.
local DAMAGE_FINALIZE_SITE_RVA = 0x2A4936
local DAMAGE_FINALIZE_ORIGINAL_BYTES = {
    0x8B, 0x49, 0x6C, 0xE8, 0x82, 0x64, 0x0E, 0x00,
}

-- Three verified native Tech paths. Each first submits the Tech popup and then
-- calls/jumps to the general EXP routine. Only these Tech-specific sites are
-- changed; the two enemy-defeat EXP sites remain native.
local TECH_POPUP_SITE_A_RVA = 0x2B4E8C
local TECH_POPUP_SITE_A_ORIGINAL = {
    0xE8, 0xFF, 0xBA, 0xFB, 0xFF,
}
local TECH_AWARD_SITE_A_RVA = 0x2B4E93
local TECH_AWARD_SITE_A_ORIGINAL = {
    0xE8, 0xF8, 0xFA, 0xFC, 0xFF,
}

local TECH_POPUP_SITE_B_RVA = 0x2BCA00
local TECH_POPUP_SITE_B_ORIGINAL = {
    0xE8, 0x8B, 0x3F, 0xFB, 0xFF,
}
local TECH_AWARD_SITE_B_RVA = 0x2BCA0D
local TECH_AWARD_SITE_B_ORIGINAL = {
    0xE9, 0x7E, 0x7F, 0xFC, 0xFF,
}

local TECH_POPUP_SITE_C_RVA = 0x2BCAA2
local TECH_POPUP_SITE_C_ORIGINAL = {
    0xE8, 0xA9, 0x3E, 0xFB, 0xFF,
}
local TECH_AWARD_SITE_C_RVA = 0x2BCAAA
local TECH_AWARD_SITE_C_ORIGINAL = {
    0xE8, 0xE1, 0x7E, 0xFC, 0xFF,
}

-- NumericHudV1.9's private code ends at module+0x3AFE20. This region starts
-- after a 0x20-byte
-- guard gap and ends exactly at the next PE section boundary.
local CAVE_RVA = 0x3AFE40
local CAVE_REGION_SIZE = 0x1C0
local CAVE_STATIC_SIZE = 0xA0
local LEGACY_CAVE_STATIC_SIZE = 0x70
local OUTGOING_CODE_OFFSET = 0xD0
local OUTGOING_CODE_SIZE = 0xB0

local TECH_AWARD_WRAPPER_RVA = CAVE_RVA + 0x00
local DAMAGE_FINALIZE_WRAPPER_RVA = CAVE_RVA + 0x20
local LIMIT_VALUE_RVA = CAVE_RVA + 0xA0
local TECH_CANDIDATE_SEQUENCE_RVA = CAVE_RVA + 0xA4
local DAMAGE_SEQUENCE_RVA = CAVE_RVA + 0xA8
local LAST_ORIGINAL_DELTA_RVA = CAVE_RVA + 0xAC
local LAST_REDUCED_DELTA_RVA = CAVE_RVA + 0xB0
local PROTECTED_DAMAGE_SEQUENCE_RVA = CAVE_RVA + 0xB4
local LIMIT_RESTORE_MODIFIER_RVA = CAVE_RVA + 0xB8
local LIMIT_LOSS_MODIFIER_RVA = CAVE_RVA + 0xBC
local CAVE_SORA_POINTER_RVA = CAVE_RVA + 0xC0
local OUTGOING_DAMAGE_SEQUENCE_RVA = CAVE_RVA + 0xC8
local LAST_OUTGOING_ORIGINAL_RVA = CAVE_RVA + 0xCC
local OUTGOING_DAMAGE_WRAPPER_RVA = CAVE_RVA + 0xD0
local LAST_OUTGOING_SCALED_RVA = CAVE_RVA + 0x1A0
local LAST_OUTGOING_LIMIT_RVA = CAVE_RVA + 0x1A4
local LAST_OUTGOING_TIER_RVA = CAVE_RVA + 0x1A8
local LIMIT_POST_MULTIPLIER_HELPER_RVA = CAVE_RVA + 0x12C
local LIMIT_PENDING_TARGET_RVA = CAVE_RVA + 0x180
local LIMIT_INTERFACE_SENTINEL_RVA = CAVE_RVA + 0x188
local LIMIT_INTERFACE_SENTINEL = 0x4C494D36

-- KHFM_EnemyConfig v4.4.31 uses this exact LIMIT-aware prefix while the
-- helper is available. Restoring the full standalone prefix before clearing
-- the LIMIT cave makes CONFIG.ENABLE=false safe during an F1 reload.
local ENEMY_HOOK_CODE_RVA = 0x3AF150
local ENEMY_LIMIT_CODE_BYTES = {
    0x48, 0x89, 0xCE, 0x41, 0x89, 0xD6, 0x45, 0x85,
    0xF6, 0x79, 0x57, 0x48, 0x3B, 0x0D, 0x52, 0x00,
    0x00, 0x00, 0x74, 0x3C, 0x8B, 0x41, 0x6C, 0x4C,
    0x8D, 0x05, 0x52, 0x00, 0x00, 0x00, 0x31, 0xC9,
    0xB1, 0x04, 0x41, 0x3B, 0x00, 0x74, 0x19, 0x49,
    0x83, 0xC0, 0x10, 0xFF, 0xC9, 0x75, 0xF3, 0x4C,
    0x8D, 0x05, 0x6A, 0x0E, 0x00, 0x00, 0xF3, 0x41,
    0x0F, 0x2A, 0xC6, 0xE9, 0xDC, 0x0D, 0x00, 0x00,
    0xF3, 0x41, 0x0F, 0x2A, 0xC6, 0xF3, 0x41, 0x0F,
    0x59, 0x40, 0x04, 0xE9, 0xCC, 0x0D, 0x00, 0x00,
    0xF3, 0x41, 0x0F, 0x2A, 0xC6, 0xF3, 0x0F, 0x59,
    0x05, 0x0F, 0x00, 0x00, 0x00, 0xF3, 0x44, 0x0F,
    0x2C, 0xF0, 0xC3, 0x00,
}
local ENEMY_BASELINE_CODE_BYTES = {
    0x48, 0x89, 0xCE, 0x41, 0x89, 0xD6, 0x45, 0x85,
    0xF6, 0x79, 0x57, 0x48, 0x3B, 0x0D, 0x52, 0x00,
    0x00, 0x00, 0x74, 0x3C, 0x8B, 0x41, 0x6C, 0x4C,
    0x8D, 0x05, 0x52, 0x00, 0x00, 0x00, 0x41, 0xB9,
    0x04, 0x00, 0x00, 0x00, 0x41, 0x3B, 0x00, 0x74,
    0x0A, 0x49, 0x83, 0xC0, 0x10, 0x41, 0xFF, 0xC9,
    0x75, 0xF2, 0xC3, 0xF3, 0x41, 0x0F, 0x2A, 0xC6,
    0xF3, 0x41, 0x0F, 0x59, 0x40, 0x04, 0xF3, 0x41,
    0x0F, 0x5F, 0x40, 0x08, 0xF3, 0x41, 0x0F, 0x5D,
    0x40, 0x0C, 0xF3, 0x44, 0x0F, 0x2C, 0xF0, 0xC3,
    0xF3, 0x41, 0x0F, 0x2A, 0xC6, 0xF3, 0x0F, 0x59,
    0x05, 0x0F, 0x00, 0x00, 0x00, 0xF3, 0x44, 0x0F,
    0x2C, 0xF0, 0xC3, 0x00,
}

-- Stable internal equipment interface for this build. Values are signed
-- 32-bit additive modifiers; Lua allows signed event results while the native
-- finalized-damage path clamps its immediate loss to 0..100.
local EQUIPMENT_INTERFACE = {
    RESTORE_MODIFIER_RVA = LIMIT_RESTORE_MODIFIER_RVA,
    LOSS_MODIFIER_RVA = LIMIT_LOSS_MODIFIER_RVA,
}

-- Assembled for module+0x3AFE40. Mutable data begins at +0xA0.
local CAVE_IMAGE = {
    0xFF, 0x05, 0x9E, 0x00, 0x00, 0x00, 0x31, 0xC0,
    0xC3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x45, 0x85, 0xF6, 0x7D, 0x71, 0x48, 0x3B, 0x35,
    0x94, 0x00, 0x00, 0x00, 0x75, 0x68, 0x44, 0x89,
    0x35, 0x77, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x6D,
    0x00, 0x00, 0x00, 0x8B, 0x05, 0x5F, 0x00, 0x00,
    0x00, 0x85, 0xC0, 0x7E, 0x51, 0x41, 0x89, 0xC2,
    0x45, 0x6B, 0xF6, 0x04, 0x41, 0x83, 0xEE, 0x04,
    0x44, 0x89, 0xF0, 0x99, 0xB9, 0x05, 0x00, 0x00,
    0x00, 0xF7, 0xF9, 0x41, 0x89, 0xC6, 0x44, 0x89,
    0x35, 0x4B, 0x00, 0x00, 0x00, 0x44, 0x8B, 0x1D,
    0x50, 0x00, 0x00, 0x00, 0x41, 0x83, 0xC3, 0x05,
    0x79, 0x03, 0x45, 0x31, 0xDB, 0x41, 0x83, 0xFB,
    0x64, 0x7E, 0x06, 0x41, 0xBB, 0x64, 0x00, 0x00,
    0x00, 0x45, 0x29, 0xDA, 0x79, 0x03, 0x45, 0x31,
    0xD2, 0x44, 0x89, 0x15, 0x10, 0x00, 0x00, 0x00,
    0xFF, 0x05, 0x1E, 0x00, 0x00, 0x00, 0x8B, 0x4E,
    0x6C, 0xE9, 0xE2, 0xAE, 0xFD, 0xFF, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x48, 0x83, 0xEC, 0x38, 0x48, 0x89, 0x4C, 0x24,
    0x20, 0x48, 0x89, 0x54, 0x24, 0x28, 0xE8, 0x5D,
    0xFB, 0xF0, 0xFF, 0x89, 0x44, 0x24, 0x30, 0x89,
    0x44, 0x24, 0x34, 0x85, 0xC0, 0x0F, 0x8E, 0x81,
    0x00, 0x00, 0x00, 0x4C, 0x8B, 0x54, 0x24, 0x20,
    0x41, 0x8B, 0x4A, 0x34, 0xE8, 0x7F, 0xAE, 0xFD,
    0xFF, 0x48, 0x85, 0xC0, 0x74, 0x6E, 0x48, 0x3B,
    0x05, 0xB3, 0xFF, 0xFF, 0xFF, 0x75, 0x65, 0x48,
    0x3B, 0x44, 0x24, 0x28, 0x74, 0x5E, 0x8B, 0x0D,
    0x84, 0xFF, 0xFF, 0xFF, 0x83, 0xF9, 0x14, 0x7C,
    0x53, 0x41, 0x89, 0xCB, 0x89, 0xC8, 0x31, 0xD2,
    0x41, 0xB9, 0x14, 0x00, 0x00, 0x00, 0x41, 0xF7,
    0xF1, 0x83, 0xF8, 0x05, 0x7E, 0x05, 0xB8, 0x05,
    0x00, 0x00, 0x00, 0x41, 0x89, 0xC1, 0x83, 0xC0,
    0x02, 0x0F, 0xAF, 0x44, 0x24, 0x30, 0xD1, 0xE8,
    0x89, 0x44, 0x24, 0x30, 0x8B, 0x54, 0x24, 0x30,
    0x89, 0x15, 0x4A, 0x00, 0x00, 0x00, 0x8B, 0x54,
    0x24, 0x34, 0x89, 0x15, 0x6C, 0xFF, 0xFF, 0xFF,
    0x44, 0x89, 0x1D, 0x3D, 0x00, 0x00, 0x00, 0x44,
    0x89, 0x0D, 0x3A, 0x00, 0x00, 0x00, 0xFF, 0x05,
    0x54, 0xFF, 0xFF, 0xFF, 0x8B, 0x44, 0x24, 0x30,
    0x48, 0x83, 0xC4, 0x38, 0xC3, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
}

-- Preserve the exact v1.5 producer/scaler bytes for safe F1 migration before
-- replacing the outgoing region with v1.6's marker producer, post-multiplier
-- helper, sentinel, and discrete 1.0/1.2/1.4/1.6/1.8/2.0 factor table.
local LEGACY_V1_5_OUTGOING_CODE = {}
do
    local index
    for index = 1, OUTGOING_CODE_SIZE do
        LEGACY_V1_5_OUTGOING_CODE[index] =
            CAVE_IMAGE[OUTGOING_CODE_OFFSET + index] or 0
    end
end

do
    local v1_6_outgoing_image = {
        0x48, 0x83, 0xEC, 0x38, 0x48, 0x89, 0x4C, 0x24,
        0x20, 0x48, 0x89, 0x54, 0x24, 0x28, 0xE8, 0x5D,
        0xFB, 0xF0, 0xFF, 0x89, 0x44, 0x24, 0x30, 0x45,
        0x31, 0xDB, 0x4C, 0x89, 0x1D, 0x8F, 0x00, 0x00,
        0x00, 0x85, 0xC0, 0x7E, 0x2E, 0x48, 0x8B, 0x4C,
        0x24, 0x20, 0x8B, 0x49, 0x34, 0xE8, 0x7E, 0xAE,
        0xFD, 0xFF, 0x48, 0x85, 0xC0, 0x74, 0x1C, 0x48,
        0x3B, 0x05, 0xB2, 0xFF, 0xFF, 0xFF, 0x75, 0x13,
        0x48, 0x3B, 0x44, 0x24, 0x28, 0x74, 0x0C, 0x48,
        0x8B, 0x54, 0x24, 0x28, 0x48, 0x89, 0x15, 0x5D,
        0x00, 0x00, 0x00, 0x8B, 0x44, 0x24, 0x30, 0x48,
        0x83, 0xC4, 0x38, 0xC3, 0x48, 0x3B, 0x35, 0x4D,
        0x00, 0x00, 0x00, 0x75, 0x36, 0x48, 0xC7, 0x05,
        0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x8B, 0x05, 0x5A, 0xFF, 0xFF, 0xFF, 0x83, 0xF8,
        0x14, 0x7C, 0x20, 0x31, 0xD2, 0xB9, 0x14, 0x00,
        0x00, 0x00, 0xF7, 0xF1, 0x83, 0xF8, 0x05, 0x7E,
        0x05, 0xB8, 0x05, 0x00, 0x00, 0x00, 0x4C, 0x8D,
        0x15, 0x2B, 0x00, 0x00, 0x00, 0xF3, 0x41, 0x0F,
        0x59, 0x04, 0x82, 0xF3, 0x41, 0x0F, 0x5F, 0x40,
        0x08, 0xF3, 0x41, 0x0F, 0x5D, 0x40, 0x0C, 0xF3,
        0x44, 0x0F, 0x2C, 0xF0, 0xC3, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x36, 0x4D, 0x49, 0x4C, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x80, 0x3F, 0x9A, 0x99, 0x99, 0x3F,
        0x33, 0x33, 0xB3, 0x3F, 0xCD, 0xCC, 0xCC, 0x3F,
        0x66, 0x66, 0xE6, 0x3F, 0x00, 0x00, 0x00, 0x40,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3F,
        0x00, 0x00, 0x00, 0xCF, 0x00, 0x00, 0x00, 0x00,
    }
    local index
    for index = 1, #v1_6_outgoing_image do
        CAVE_IMAGE[OUTGOING_CODE_OFFSET + index] =
            v1_6_outgoing_image[index]
    end
end

-- Exact v1.2 code prefix. V1.2, v1.1, and v1 stored LIMIT at +0x70;
-- install_hooks migrates that value to v1.4's +0xA0 slot.
local LEGACY_V1_2_CAVE_STATIC = {
    0xFF, 0x05, 0x6E, 0x00, 0x00, 0x00, 0x31, 0xC0,
    0xC3, 0x66, 0x66, 0x2E, 0x0F, 0x1F, 0x84, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x66, 0x66, 0x2E, 0x0F,
    0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90,
    0x45, 0x85, 0xF6, 0x7D, 0x3D, 0x48, 0x3B, 0x35,
    0x64, 0x00, 0x00, 0x00, 0x75, 0x34, 0x44, 0x89,
    0x35, 0x47, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x3D,
    0x00, 0x00, 0x00, 0x8B, 0x05, 0x2F, 0x00, 0x00,
    0x00, 0x85, 0xC0, 0x7E, 0x1D, 0x41, 0xD1, 0xFE,
    0x44, 0x89, 0x35, 0x31, 0x00, 0x00, 0x00, 0x83,
    0xE8, 0x01, 0x79, 0x02, 0x31, 0xC0, 0x89, 0x05,
    0x14, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x22, 0x00,
    0x00, 0x00, 0x8B, 0x4E, 0x6C, 0xE9, 0x16, 0xAF,
    0xFD, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
}

-- Exact v1.1 code prefix, derived from v1.2. The only native-code difference
-- is the finalized-hit LIMIT-cost immediate at byte offset +0x51.
local LEGACY_V1_1_CAVE_STATIC = {}
local legacy_v1_1_index
for legacy_v1_1_index = 1, LEGACY_CAVE_STATIC_SIZE do
    LEGACY_V1_1_CAVE_STATIC[legacy_v1_1_index] =
        LEGACY_V1_2_CAVE_STATIC[legacy_v1_1_index]
end
LEGACY_V1_1_CAVE_STATIC[0x51 + 1] = 0x02

-- Exact v1 code prefix, used only to recognize and safely upgrade an F1-loaded
-- legacy installation. Mutable LIMIT at +0x70 is preserved during the upgrade.
local LEGACY_V1_CAVE_STATIC = {
    0x8B, 0x05, 0x6A, 0x00, 0x00, 0x00, 0x83, 0xF8,
    0x0A, 0x7D, 0x08, 0xFF, 0xC0, 0x89, 0x05, 0x5D,
    0x00, 0x00, 0x00, 0xFF, 0x05, 0x5B, 0x00, 0x00,
    0x00, 0x31, 0xC0, 0xC3, 0x0F, 0x1F, 0x40, 0x00,
    0x45, 0x85, 0xF6, 0x7D, 0x37, 0x48, 0x3B, 0x35,
    0x5C, 0x00, 0x00, 0x00, 0x75, 0x2E, 0x8B, 0x05,
    0x3C, 0x00, 0x00, 0x00, 0x85, 0xC0, 0x7E, 0x24,
    0x44, 0x89, 0x35, 0x3D, 0x00, 0x00, 0x00, 0x41,
    0xD1, 0xFE, 0x44, 0x89, 0x35, 0x37, 0x00, 0x00,
    0x00, 0x83, 0xE8, 0x02, 0x79, 0x02, 0x31, 0xC0,
    0x89, 0x05, 0x1A, 0x00, 0x00, 0x00, 0xFF, 0x05,
    0x1C, 0x00, 0x00, 0x00, 0x8B, 0x4E, 0x6C, 0xE9,
    0x1C, 0xAF, 0xFD, 0xFF,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
}

local NATIVE_SIGNATURES = {
    {
        rva = POINTER_RESOLVER_RVA,
        name = "decoded-stat resolver",
        bytes = {
            0x85, 0xC9, 0x75, 0x03, 0x33, 0xC0,
            0xC3, 0xE9, 0x74, 0x01, 0x00, 0x00,
        },
    },
    {
        rva = FINAL_HP_ADJUST_RVA,
        name = "final HP-adjust routine",
        bytes = {
            0x48, 0x89, 0x74, 0x24, 0x10,
            0x48, 0x89, 0x7C, 0x24, 0x18,
            0x41, 0x56, 0x48, 0x83, 0xEC, 0x20,
        },
    },
    {
        rva = DAMAGE_FORMULA_RVA,
        name = "shared native attack/spell damage formula",
        bytes = {
            0x48, 0x89, 0x5C, 0x24, 0x08,
            0x48, 0x89, 0x6C, 0x24, 0x10,
            0x48, 0x89, 0x74, 0x24, 0x18,
            0x48, 0x89, 0x7C, 0x24, 0x20,
            0x41, 0x54, 0x41, 0x56, 0x41, 0x57,
        },
    },
    {
        rva = 0x270950,
        name = "native Tech world-position popup routine",
        bytes = {
            0x48, 0x89, 0x5C, 0x24, 0x08, 0x57,
            0x48, 0x83, 0xEC, 0x20,
        },
    },
    {
        rva = 0x270990,
        name = "native Tech entity-position popup routine",
        bytes = {
            0x48, 0x89, 0x5C, 0x24, 0x10,
            0x48, 0x89, 0x74, 0x24, 0x18,
            0x57, 0x48, 0x83, 0xEC, 0x40,
        },
    },
    {
        rva = 0x284990,
        name = "native EXP award routine",
        bytes = {
            0x48, 0x89, 0x5C, 0x24, 0x18,
            0x89, 0x4C, 0x24, 0x08,
            0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55,
        },
    },
}

local gear_runtime = {
    initialized = false,
    signature = nil,
    level = nil,
    experience = nil,
    applied = { hp = 0, mp = 0, str = 0, def = 0 },
    expected = { hp = nil, mp = nil, str = nil, def = nil },
    applied_resistance = {
        fire = 0, ice = 0, lightning = 0, dark = 0,
    },
    expected_resistance = {
        fire = nil, ice = nil, lightning = nil, dark = nil,
    },
    owned_abilities = {},
    desired_limit = 0,
    desired_risk = 0,
}

local runtime = {
    initialized = false,
    stopped = false,
    waiting_logged = false,
    persistence_available = false,
    state_path = nil,
    last_limit = 0,
    last_tech_candidate_sequence = 0,
    last_damage_sequence = 0,
    last_protected_damage_sequence = 0,
    last_outgoing_damage_sequence = 0,
    last_sora = 0,
    frame = 0,
    previous_animation = nil,
    previous_animation_time = nil,
    pending_tech_candidates = {},
    parry_dedupe_frame = -1000,
    parry_dedupe_credit = 0,
    last_restore_modifier = nil,
    last_loss_modifier = nil,
    last_equipment_signature = nil,
    cached_hertz = 60,
    persistence_interval_frames = 60,
    last_persistence_save_frame = 0,
    persistence_dirty = false,
    pending_persisted_limit = 0,
    summary_interval_frames = 600,
    last_summary_frame = 0,
    summary = {
        defense_events = 0,
        limit_restored = 0,
        damaging_hits = 0,
        protected_hits = 0,
        outgoing_hits = 0,
        rejected_candidates = 0,
        persistence_writes = 0,
        risk_limit_generated = 0,
    },
}

local function log(message)
    ConsolePrint(PREFIX .. tostring(message))
end

local function debug_enabled(category)
    return CONFIG.DEBUG_MODE == true and category ~= false
end

local function safe_read_array(address, length)
    local ok, value = pcall(ReadArray, address, length, false)
    if not ok or value == nil then
        return nil
    end
    local length_ok, actual_length = pcall(function()
        return #value
    end)
    if not length_ok or actual_length < length then
        return nil
    end
    return value
end

local function arrays_equal(left, right)
    if left == nil or right == nil or #left ~= #right then
        return false
    end
    local index
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function arrays_equal_prefix(left, right, length)
    if left == nil or right == nil or #left < length or #right < length then
        return false
    end
    local index
    for index = 1, length do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function is_zero_array(bytes)
    if bytes == nil then
        return false
    end
    local index
    for index = 1, #bytes do
        if bytes[index] ~= 0 then
            return false
        end
    end
    return true
end

local function safe_write_array(address, bytes)
    local ok, reason = pcall(WriteArray, address, bytes, false)
    if not ok then
        return false, tostring(reason)
    end
    local readback = safe_read_array(address, #bytes)
    if not arrays_equal(readback, bytes) then
        return false, "write did not verify"
    end
    return true
end

local function safe_read_int(address)
    local ok, value = pcall(ReadInt, address, false)
    if not ok or value == nil then
        return nil
    end
    if value < 0 then
        return value + 4294967296
    end
    return value
end

local function safe_read_signed_int(address)
    local ok, value = pcall(ReadInt, address, false)
    if not ok or value == nil then
        return nil
    end
    if value > 2147483647 then
        return value - 4294967296
    end
    return value
end

local function safe_write_int(address, value)
    local ok, reason = pcall(WriteInt, address, value, false)
    if not ok then
        return false, tostring(reason)
    end
    local readback = safe_read_int(address)
    local expected = value % 4294967296
    if readback ~= expected then
        return false, "integer write did not verify"
    end
    return true
end

local function safe_read_long(address)
    local ok, value = pcall(ReadLong, address, false)
    if not ok or value == nil then
        return nil
    end
    return value
end

local function safe_read_byte_relative(address)
    local ok, value = pcall(ReadByte, address, false)
    if not ok or value == nil then
        return nil
    end
    return value
end

local function safe_read_byte_absolute(address)
    local ok, value = pcall(ReadByte, address, true)
    if not ok or value == nil then
        return nil
    end
    return value
end

local function safe_read_float_absolute(address)
    local ok, value = pcall(ReadFloat, address, true)
    if not ok or value == nil then
        return nil
    end
    return value
end

local function safe_read_float_relative(address)
    local ok, value = pcall(ReadFloat, address, false)
    if not ok or value == nil or value ~= value
        or value < -1000000 or value > 1000000 then
        return nil
    end
    return value
end

local function safe_write_byte_relative(address, value)
    local byte = math.floor(tonumber(value) or 0) % 256
    local ok, reason = pcall(WriteByte, address, byte, false)
    if not ok then
        return false, tostring(reason)
    end
    if safe_read_byte_relative(address) ~= byte then
        return false, "byte write did not verify"
    end
    return true
end

local function safe_write_float_relative(address, value)
    local number = tonumber(value)
    if number == nil or number ~= number then
        return false, "invalid float"
    end
    local ok, reason = pcall(WriteFloat, address, number, false)
    if not ok then
        return false, tostring(reason)
    end
    local readback = safe_read_float_relative(address)
    if readback == nil or math.abs(readback - number) > 0.0001 then
        return false, "float write did not verify"
    end
    return true
end

local function safe_write_long(address, value)
    local ok, reason = pcall(WriteLong, address, value, false)
    if not ok then
        return false, tostring(reason)
    end
    local readback = safe_read_long(address)
    if readback ~= value then
        return false, "pointer write did not verify"
    end
    return true
end

local function read_runtime_hertz()
    local ok, value = pcall(GetHertz)
    local hertz = tonumber(value)
    if not ok or hertz == nil or hertz < 1 or hertz > 1000 then
        return 60
    end
    return math.max(1, math.floor(hertz + 0.5))
end

local function seconds_to_frames(seconds, hertz)
    local value = tonumber(seconds) or 0
    if value <= 0 then
        return 1
    end
    return math.max(1, math.floor(value * hertz + 0.5))
end

local function clamp_limit(value)
    local number = math.floor(tonumber(value)
        or CONFIG.STARTING_LIMIT_WITHOUT_STATE or 0)
    if number < 0 then
        return 0
    end
    if number > MAX_LIMIT then
        return MAX_LIMIT
    end
    return number
end

local function clamp_modifier(value)
    local number = math.floor(tonumber(value) or 0)
    if number < -MAX_LIMIT then
        return -MAX_LIMIT
    end
    if number > MAX_LIMIT then
        return MAX_LIMIT
    end
    return number
end

local function effective_limit_amount(base, modifier)
    local amount = math.floor((tonumber(base) or 0)
        + (tonumber(modifier) or 0))
    if amount < -MAX_LIMIT then
        return -MAX_LIMIT
    end
    if amount > MAX_LIMIT then
        return MAX_LIMIT
    end
    return amount
end

local GEAR_CONTROLLER = {}
do
    local ELEMENTS = { "fire", "ice", "lightning", "dark" }
    local RESISTANCE_EPSILON = 0.0002

    local function normalize_name(value)
        if type(value) ~= "string" then
            return ""
        end
        return string.lower(value):gsub("[^%w]", "")
    end

    local function clamp(value, minimum, maximum)
        if value < minimum then
            return minimum
        end
        if value > maximum then
            return maximum
        end
        return value
    end

    local function whole_number(value, fallback)
        local number = tonumber(value)
        if number == nil then
            return fallback
        end
        if number >= 0 then
            return math.floor(number + 0.00001)
        end
        return math.ceil(number - 0.00001)
    end

    local function field_number(row, upper, lower)
        if row[upper] ~= nil then
            return whole_number(row[upper], 0)
        end
        if row[lower] ~= nil then
            return whole_number(row[lower], 0)
        end
        return 0
    end

    local function resolve_ability_id(value)
        if type(value) == "number" then
            local id = whole_number(value, -1)
            if id >= 1 and id <= 0x7F then
                return id
            end
            return nil
        end
        if type(value) == "string" then
            return NORMALIZED_ABILITY_IDS[normalize_name(value)]
        end
        return nil
    end

    local function compile_rows(rows, minimum_id, maximum_id)
        local configured_name
        local row
        for configured_name, row in pairs(rows) do
            if type(row) ~= "table" then
                log("CONFIG ERROR: " .. tostring(configured_name)
                    .. " is not a table.")
            elseif row.ENABLED ~= false and row.enabled ~= false then
                local id = NAME_TO_EQUIPMENT_ID[
                    normalize_name(configured_name)
                ]
                if id == nil then
                    log("CONFIG ERROR: unknown equipment name '"
                        .. tostring(configured_name) .. "'.")
                elseif id < minimum_id or id > maximum_id then
                    log("CONFIG ERROR: " .. tostring(configured_name)
                        .. " is in the wrong equipment table.")
                elseif COMPILED_GEAR_BY_ID[id] ~= nil then
                    log("CONFIG ERROR: duplicate equipment row for "
                        .. tostring(EQUIPMENT_NAMES[id]) .. ".")
                else
                    local compiled = {
                        name = EQUIPMENT_NAMES[id],
                        hp = clamp(field_number(row, "HP", "hp"), -255, 255),
                        mp = clamp(field_number(row, "MP", "mp"), -255, 255),
                        str = clamp(field_number(row, "STR", "str"), -255, 255),
                        def = clamp(field_number(row, "DEF", "def"), -255, 255),
                        fire = clamp(field_number(
                            row, "FIRE_RESISTANCE", "fire_resistance"
                        ), -1000, 1000),
                        ice = clamp(field_number(
                            row, "ICE_RESISTANCE", "ice_resistance"
                        ), -1000, 1000),
                        lightning = clamp(field_number(
                            row,
                            "LIGHTNING_RESISTANCE",
                            "lightning_resistance"
                        ), -1000, 1000),
                        dark = clamp(field_number(
                            row, "DARK_RESISTANCE", "dark_resistance"
                        ), -1000, 1000),
                        limit = clamp(field_number(
                            row, "LIMIT", "limit"
                        ), -100, 100),
                        risk = clamp(field_number(
                            row, "RISK", "risk"
                        ), -100, 100),
                        abilities = {},
                    }
                    local abilities = row.ABILITIES or row.abilities or {}
                    if type(abilities) ~= "table" then
                        log("CONFIG ERROR: abilities for "
                            .. compiled.name .. " must be a table.")
                        abilities = {}
                    end
                    local index
                    for index = 1, #abilities do
                        local ability_id = resolve_ability_id(
                            abilities[index]
                        )
                        if ability_id == nil then
                            log("CONFIG ERROR: unknown ability '"
                                .. tostring(abilities[index]) .. "' on "
                                .. compiled.name .. ".")
                        else
                            compiled.abilities[ability_id] = true
                        end
                    end
                    COMPILED_GEAR_BY_ID[id] = compiled
                end
            end
        end
    end

    function GEAR_CONTROLLER.compile()
        NAME_TO_EQUIPMENT_ID = {}
        NORMALIZED_ABILITY_IDS = {}
        ABILITY_NAMES_BY_ID = {}
        COMPILED_GEAR_BY_ID = {}

        local id
        local name
        for id, name in pairs(EQUIPMENT_NAMES) do
            NAME_TO_EQUIPMENT_ID[normalize_name(name)] = id
        end
        NAME_TO_EQUIPMENT_ID[normalize_name("Crab Claw")] = 0x5A
        NAME_TO_EQUIPMENT_ID[normalize_name("One Winged Angel")] = 0x66
        NAME_TO_EQUIPMENT_ID[normalize_name("Dream Shield")] = 0x53
        NAME_TO_EQUIPMENT_ID[normalize_name("Dream Rod")] = 0x54

        for name, id in pairs(SORA_ABILITY_IDS) do
            NORMALIZED_ABILITY_IDS[normalize_name(name)] = id
            ABILITY_NAMES_BY_ID[id] = name
        end
        NORMALIZED_ABILITY_IDS[normalize_name("Counter Attack")] = 0x13

        compile_rows(KEYBLADES, 0x51, 0x66)
        compile_rows(ACCESSORIES, 0x11, 0x47)

        local count = 0
        for id, _ in pairs(COMPILED_GEAR_BY_ID) do
            count = count + 1
        end
        return count
    end

    local function read_equipment()
        local weapon = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.WEAPON
        )
        if weapon == nil then
            return nil, "weapon byte is unreadable"
        end
        local equipment = { weapon = weapon, accessories = {} }
        local index
        for index = 0, SORA_ACCESSORY_SLOT_CAPACITY - 1 do
            local item = safe_read_byte_relative(
                SORA_CHARACTER_BASE_RVA
                    + CHARACTER_OFFSET.ACCESSORIES + index
            )
            if item == nil then
                return nil, "accessory slot " .. tostring(index + 1)
                    .. " is unreadable"
            end
            equipment.accessories[index + 1] = item
        end
        return equipment, nil
    end

    local function equipment_signature(equipment)
        local parts = { string.format("%02X", equipment.weapon) }
        local index
        for index = 1, SORA_ACCESSORY_SLOT_CAPACITY do
            parts[#parts + 1] = string.format(
                "%02X", equipment.accessories[index] or 0
            )
        end
        return table.concat(parts, ":")
    end

    local function equipment_description(equipment)
        local counts = {}
        local order = {}
        local function add(id)
            if id == 0 then
                return
            end
            local name = EQUIPMENT_NAMES[id]
                or string.format("Unknown 0x%02X", id)
            if counts[name] == nil then
                counts[name] = 0
                order[#order + 1] = name
            end
            counts[name] = counts[name] + 1
        end
        add(equipment.weapon)
        local index
        for index = 1, SORA_ACCESSORY_SLOT_CAPACITY do
            add(equipment.accessories[index] or 0)
        end
        local parts = {}
        for index = 1, #order do
            local name = order[index]
            if counts[name] > 1 then
                parts[#parts + 1] = name .. " x" .. tostring(counts[name])
            else
                parts[#parts + 1] = name
            end
        end
        if #parts == 0 then
            return "(none)"
        end
        return table.concat(parts, ", ")
    end

    local function calculate_desired(equipment)
        local desired = {
            hp = 0, mp = 0, str = 0, def = 0,
            fire = 0, ice = 0, lightning = 0, dark = 0,
            limit = 0, risk = 0,
            abilities = {}, active_rows = {},
        }
        local function add(id)
            local row = COMPILED_GEAR_BY_ID[id]
            if row == nil then
                return
            end
            desired.hp = desired.hp + row.hp
            desired.mp = desired.mp + row.mp
            desired.str = desired.str + row.str
            desired.def = desired.def + row.def
            desired.fire = desired.fire + row.fire
            desired.ice = desired.ice + row.ice
            desired.lightning = desired.lightning + row.lightning
            desired.dark = desired.dark + row.dark
            desired.limit = desired.limit + row.limit
            desired.risk = desired.risk + row.risk
            desired.active_rows[#desired.active_rows + 1] = row.name
            local ability_id
            for ability_id, enabled in pairs(row.abilities) do
                if enabled then
                    desired.abilities[ability_id] =
                        (desired.abilities[ability_id] or 0) + 1
                end
            end
        end
        add(equipment.weapon)
        local index
        for index = 1, SORA_ACCESSORY_SLOT_CAPACITY do
            add(equipment.accessories[index] or 0)
        end
        desired.hp = clamp(desired.hp, -2040, 2040)
        desired.mp = clamp(desired.mp, -2040, 2040)
        desired.str = clamp(desired.str, -2040, 2040)
        desired.def = clamp(desired.def, -2040, 2040)
        desired.fire = clamp(desired.fire, -8000, 8000)
        desired.ice = clamp(desired.ice, -8000, 8000)
        desired.lightning = clamp(desired.lightning, -8000, 8000)
        desired.dark = clamp(desired.dark, -8000, 8000)
        desired.limit = clamp_modifier(desired.limit)
        desired.risk = clamp_modifier(desired.risk)
        return desired
    end

    local function read_stats()
        local current_hp = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_HP
        )
        local hp = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.MAX_HP
        )
        local current_mp = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_MP
        )
        local mp = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.MAX_MP
        )
        local str = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.STRENGTH
        )
        local def = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.DEFENSE
        )
        if current_hp == nil or hp == nil or current_mp == nil
            or mp == nil or str == nil or def == nil then
            return nil, "one or more Sora stat bytes are unreadable"
        end
        return {
            current_hp = current_hp, hp = hp,
            current_mp = current_mp, mp = mp,
            str = str, def = def,
        }, nil
    end

    local function read_progress()
        local level = safe_read_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.LEVEL
        )
        local experience = safe_read_int(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.EXPERIENCE
        )
        if level == nil or experience == nil then
            return nil, nil, "Sora progress fields are unreadable"
        end
        return level, experience, nil
    end

    local function read_resistances()
        local values = {}
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            values[element] = safe_read_float_relative(
                SORA_RESISTANCE_RVA + RESISTANCE_OFFSET[element]
            )
            if values[element] == nil then
                return nil, element .. " resistance is unreadable"
            end
        end
        return values, nil
    end

    local function apply_stats(desired, current)
        local old = gear_runtime.applied
        local refreshed_fields = {}
        local function owned_baseline(field)
            local current_value = current[field]
            local expected_value = gear_runtime.expected[field]
            local owned_delta = old[field] or 0
            if expected_value ~= nil and current_value == expected_value then
                return current_value - owned_delta
            end
            if expected_value ~= nil and owned_delta ~= 0 then
                refreshed_fields[#refreshed_fields + 1] = field
            end
            -- KH1 or another compatible controller rebuilt this byte. The
            -- current value is already the new native/external baseline; do
            -- not subtract our old delta from it a second time.
            return current_value
        end
        local baseline = {
            hp = owned_baseline("hp"),
            mp = owned_baseline("mp"),
            str = owned_baseline("str"),
            def = owned_baseline("def"),
        }
        local final = {
            hp = clamp(baseline.hp + desired.hp, 1, 255),
            mp = clamp(baseline.mp + desired.mp, 0, 255),
            str = clamp(baseline.str + desired.str, 0, 255),
            def = clamp(baseline.def + desired.def, 0, 255),
        }
        local hp_change = final.hp - current.hp
        local mp_change = final.mp - current.mp
        local ok
        local reason
        if final.hp ~= current.hp then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.MAX_HP,
                final.hp
            )
            if not ok then return false, reason end
            if CONFIG.PRESERVE_MISSING_HP and current.current_hp > 0 then
                ok, reason = safe_write_byte_relative(
                    SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_HP,
                    clamp(current.current_hp + hp_change, 1, final.hp)
                )
                if not ok then return false, reason end
            elseif current.current_hp > final.hp then
                ok, reason = safe_write_byte_relative(
                    SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_HP,
                    final.hp
                )
                if not ok then return false, reason end
            end
        end
        if final.mp ~= current.mp then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.MAX_MP,
                final.mp
            )
            if not ok then return false, reason end
            if CONFIG.PRESERVE_MISSING_MP then
                ok, reason = safe_write_byte_relative(
                    SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_MP,
                    clamp(current.current_mp + mp_change, 0, final.mp)
                )
                if not ok then return false, reason end
            elseif current.current_mp > final.mp then
                ok, reason = safe_write_byte_relative(
                    SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_MP,
                    final.mp
                )
                if not ok then return false, reason end
            end
        end
        if final.str ~= current.str then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.STRENGTH,
                final.str
            )
            if not ok then return false, reason end
        end
        if final.def ~= current.def then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.DEFENSE,
                final.def
            )
            if not ok then return false, reason end
        end
        gear_runtime.applied = {
            hp = final.hp - baseline.hp,
            mp = final.mp - baseline.mp,
            str = final.str - baseline.str,
            def = final.def - baseline.def,
        }
        gear_runtime.expected = final
        if #refreshed_fields > 0 and CONFIG.LOG_EQUIPMENT_CHANGES then
            log("STAT PAGE REFRESH: adopted live "
                .. table.concat(refreshed_fields, "/")
                .. " as a new baseline and reapplied configured equipment "
                .. "bonuses; HP=" .. tostring(final.hp)
                .. " MP=" .. tostring(final.mp)
                .. " STR=" .. tostring(final.str)
                .. " DEF=" .. tostring(final.def) .. ".")
        end
        return final.hp ~= current.hp or final.mp ~= current.mp
            or final.str ~= current.str or final.def ~= current.def, nil
    end

    local function apply_resistances(desired, current)
        local changed = false
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            local old_delta = gear_runtime.applied_resistance[element] or 0
            local expected = gear_runtime.expected_resistance[element]
            local baseline
            if expected ~= nil
                and math.abs(current[element] - expected)
                    <= RESISTANCE_EPSILON then
                baseline = current[element] - old_delta
            else
                baseline = current[element]
            end
            local requested_delta = -(desired[element] or 0) / 100
            local final = clamp(baseline + requested_delta, 0, 10)
            if math.abs(final - current[element]) > RESISTANCE_EPSILON then
                local ok, reason = safe_write_float_relative(
                    SORA_RESISTANCE_RVA + RESISTANCE_OFFSET[element],
                    final
                )
                if not ok then
                    return false, element .. " resistance write failed: "
                        .. tostring(reason)
                end
                changed = true
            end
            gear_runtime.applied_resistance[element] = final - baseline
            gear_runtime.expected_resistance[element] = final
        end
        return changed, nil
    end

    local function find_ability_byte(byte)
        local slot
        for slot = 0, ABILITY_SLOT_CAPACITY - 1 do
            if safe_read_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.ABILITIES + slot
            ) == byte then
                return slot
            end
        end
        return nil
    end

    local function release_owned_ability(ability_id, ownership)
        local address = SORA_CHARACTER_BASE_RVA
            + CHARACTER_OFFSET.ABILITIES + ownership.slot
        local current = safe_read_byte_relative(address)
        if current == ownership.expected then
            local ok, reason = safe_write_byte_relative(
                address, ownership.previous
            )
            if not ok then
                return false, reason
            end
            if CONFIG.LOG_ABILITY_CHANGES then
                log("ABILITY REMOVED: "
                    .. (ABILITY_NAMES_BY_ID[ability_id]
                        or tostring(ability_id))
                    .. " restored slot " .. tostring(ownership.slot + 1)
                    .. " to 0x" .. string.format(
                        "%02X", ownership.previous
                    ) .. ".")
            end
        elseif current == nil then
            return false, "ability slot became unreadable"
        else
            log("ABILITY OWNERSHIP RELEASED: slot "
                .. tostring(ownership.slot + 1)
                .. " changed externally, so it was left untouched.")
        end
        gear_runtime.owned_abilities[ability_id] = nil
        return true, nil
    end

    local function update_abilities(desired_abilities)
        local changed = false
        local owned_ids = {}
        local ability_id
        local ownership
        for ability_id, ownership in pairs(
            gear_runtime.owned_abilities
        ) do
            owned_ids[#owned_ids + 1] = ability_id
        end
        local index
        for index = 1, #owned_ids do
            ability_id = owned_ids[index]
            ownership = gear_runtime.owned_abilities[ability_id]
            if ownership ~= nil then
                local address = SORA_CHARACTER_BASE_RVA
                    + CHARACTER_OFFSET.ABILITIES + ownership.slot
                local current = safe_read_byte_relative(address)
                -- V2 reversed KH1FM's high-bit convention and wrote the
                -- unequipped form (ID+0x80). Migrate an exact still-owned
                -- byte to the active raw ID before normal ownership checks.
                if desired_abilities[ability_id] ~= nil
                    and current == ownership.expected
                    and ownership.expected == ability_id + 0x80 then
                    local ok, reason = safe_write_byte_relative(
                        address, ability_id
                    )
                    if not ok then return false, reason end
                    ownership.expected = ability_id
                    current = ability_id
                    changed = true
                    if CONFIG.LOG_ABILITY_CHANGES then
                        log("ABILITY MIGRATED AND ACTIVATED: "
                            .. (ABILITY_NAMES_BY_ID[ability_id]
                                or tostring(ability_id))
                            .. " changed from 0x"
                            .. string.format("%02X", ability_id + 0x80)
                            .. " to active byte 0x"
                            .. string.format("%02X", ability_id) .. ".")
                    end
                end
                if desired_abilities[ability_id] == nil
                    or current ~= ownership.expected then
                    local ok, reason = release_owned_ability(
                        ability_id, ownership
                    )
                    if not ok then return false, reason end
                    changed = true
                end
            end
        end
        for ability_id, count in pairs(desired_abilities) do
            if count > 0
                and gear_runtime.owned_abilities[ability_id] == nil then
                -- In KH1FM the raw ID is equipped/active. Adding 0x80 marks
                -- the same list entry unequipped.
                local equipped = ability_id
                local unequipped = ability_id + 0x80
                if find_ability_byte(equipped) == nil then
                    -- Prefer enabling Sora's existing unequipped copy. If he
                    -- has not learned it, create a temporary entry in a free
                    -- slot. Both paths restore the exact previous byte.
                    local slot = find_ability_byte(unequipped)
                    local previous = unequipped
                    if slot == nil then
                        slot = find_ability_byte(0)
                        previous = 0
                    end
                    if slot == nil then
                        log("ABILITY NOT GRANTED: no safe slot is available for "
                            .. (ABILITY_NAMES_BY_ID[ability_id]
                                or tostring(ability_id)) .. ".")
                    else
                        local ok, reason = safe_write_byte_relative(
                            SORA_CHARACTER_BASE_RVA
                                + CHARACTER_OFFSET.ABILITIES + slot,
                            equipped
                        )
                        if not ok then return false, reason end
                        gear_runtime.owned_abilities[ability_id] = {
                            slot = slot,
                            previous = previous,
                            expected = equipped,
                        }
                        changed = true
                        if CONFIG.LOG_ABILITY_CHANGES then
                            log("ABILITY GRANTED: "
                                .. (ABILITY_NAMES_BY_ID[ability_id]
                                    or tostring(ability_id))
                                .. " uses temporary slot "
                                .. tostring(slot + 1)
                                .. " and will restore 0x"
                                .. string.format("%02X", previous)
                                .. " when the last granting item is removed.")
                        end
                    end
                end
            end
        end
        return changed, nil
    end

    local function state_path(filename)
        if io == nil or io.open == nil or SCRIPT_PATH == nil then
            return nil
        end
        local separator = "\\"
        if package ~= nil and package.config ~= nil then
            separator = string.sub(package.config, 1, 1)
        end
        return SCRIPT_PATH .. separator
            .. tostring(filename or CONFIG.EQUIPMENT_STATE_FILENAME)
    end

    local function load_state(filename)
        local path = state_path(filename)
        if path == nil then
            return nil
        end
        local file = io.open(path, "r")
        if file == nil then
            return nil
        end
        local state = { abilities = {} }
        local line
        for line in file:lines() do
            local key, value = string.match(line, "^([%w_]+)=(.*)$")
            if key == "active" then state.active = value == "1"
            elseif key == "build" then state.build = value
            elseif key == "signature" then state.signature = value
            elseif key == "level" then state.level = tonumber(value)
            elseif key == "experience" then state.experience = tonumber(value)
            elseif key == "hp_delta" then state.hp_delta = tonumber(value)
            elseif key == "mp_delta" then state.mp_delta = tonumber(value)
            elseif key == "str_delta" then state.str_delta = tonumber(value)
            elseif key == "def_delta" then state.def_delta = tonumber(value)
            elseif key == "expected_hp" then state.expected_hp = tonumber(value)
            elseif key == "expected_mp" then state.expected_mp = tonumber(value)
            elseif key == "expected_str" then state.expected_str = tonumber(value)
            elseif key == "expected_def" then state.expected_def = tonumber(value)
            elseif string.sub(key or "", 1, 4) == "res_" then
                state[key] = tonumber(value)
            elseif key == "ability" then
                local ability, slot, previous, expected = string.match(
                    value, "^(%d+),(%d+),(%d+),(%d+)$"
                )
                if ability ~= nil then
                    state.abilities[tonumber(ability)] = {
                        slot = tonumber(slot),
                        previous = tonumber(previous),
                        expected = tonumber(expected),
                    }
                end
            end
        end
        file:close()
        return state
    end

    local function save_state()
        local path = state_path(CONFIG.EQUIPMENT_STATE_FILENAME)
        if path == nil then
            return false
        end
        local file = io.open(path, "w")
        if file == nil then
            log("WARNING: could not write "
                .. CONFIG.EQUIPMENT_STATE_FILENAME
                .. "; equipment reload protection is unavailable.")
            return false
        end
        file:write("version=4\nactive=1\nbuild=STEAM_GL\n")
        file:write("signature=", tostring(gear_runtime.signature or ""), "\n")
        file:write("level=", tostring(gear_runtime.level or 0), "\n")
        file:write("experience=", tostring(gear_runtime.experience or 0), "\n")
        file:write("hp_delta=", tostring(gear_runtime.applied.hp or 0), "\n")
        file:write("mp_delta=", tostring(gear_runtime.applied.mp or 0), "\n")
        file:write("str_delta=", tostring(gear_runtime.applied.str or 0), "\n")
        file:write("def_delta=", tostring(gear_runtime.applied.def or 0), "\n")
        file:write("expected_hp=", tostring(gear_runtime.expected.hp or 0), "\n")
        file:write("expected_mp=", tostring(gear_runtime.expected.mp or 0), "\n")
        file:write("expected_str=", tostring(gear_runtime.expected.str or 0), "\n")
        file:write("expected_def=", tostring(gear_runtime.expected.def or 0), "\n")
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            file:write("res_", element, "_delta=",
                string.format("%.9g",
                    gear_runtime.applied_resistance[element] or 0), "\n")
            file:write("res_", element, "_expected=",
                string.format("%.9g",
                    gear_runtime.expected_resistance[element] or 0), "\n")
        end
        local ability_id
        for ability_id, ownership in pairs(
            gear_runtime.owned_abilities
        ) do
            file:write("ability=", tostring(ability_id), ",",
                tostring(ownership.slot), ",",
                tostring(ownership.previous), ",",
                tostring(ownership.expected), "\n")
        end
        file:close()
        return true
    end

    local function clear_state()
        local path = state_path(CONFIG.EQUIPMENT_STATE_FILENAME)
        if path == nil then return end
        local file = io.open(path, "w")
        if file ~= nil then
            file:write("version=4\nactive=0\n")
            file:close()
        end
    end

    local function state_matches(state, signature, stats, resistances,
            level, experience)
        if state == nil or state.active ~= true
            or state.build ~= "STEAM_GL"
            or state.signature ~= signature
            or state.expected_hp ~= stats.hp
            or state.expected_mp ~= stats.mp
            or state.expected_str ~= stats.str
            or state.expected_def ~= stats.def then
            return false
        end
        -- V2/v2.1 could keep an old applied delta after KH1 had already
        -- rebuilt the character page. Reject ledgers whose implied baseline
        -- is impossible so the first v2.2 pass can adopt the live values and
        -- apply the configured bonuses normally.
        local implied_hp = state.expected_hp
            - whole_number(state.hp_delta, 0)
        local implied_mp = state.expected_mp
            - whole_number(state.mp_delta, 0)
        local implied_str = state.expected_str
            - whole_number(state.str_delta, 0)
        local implied_def = state.expected_def
            - whole_number(state.def_delta, 0)
        if implied_hp < 1 or implied_hp > 255
            or implied_mp < 0 or implied_mp > 255
            or implied_str < 0 or implied_str > 255
            or implied_def < 0 or implied_def > 255 then
            return false
        end
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            local expected = state["res_" .. element .. "_expected"]
            if expected == nil
                or math.abs(expected - resistances[element])
                    > RESISTANCE_EPSILON then
                return false
            end
        end
        return true
    end

    local function legacy_state_matches(state, signature, stats)
        return state ~= nil and state.active == true
            and state.build == "STEAM_GL"
            and state.signature == signature
            and state.expected_hp == stats.hp
            and state.expected_mp == stats.mp
            and state.expected_str == stats.str
            and state.expected_def == stats.def
            and state.expected_hp - whole_number(state.hp_delta, 0) >= 1
            and state.expected_hp - whole_number(state.hp_delta, 0) <= 255
            and state.expected_mp - whole_number(state.mp_delta, 0) >= 0
            and state.expected_mp - whole_number(state.mp_delta, 0) <= 255
            and state.expected_str - whole_number(state.str_delta, 0) >= 0
            and state.expected_str - whole_number(state.str_delta, 0) <= 255
            and state.expected_def - whole_number(state.def_delta, 0) >= 0
            and state.expected_def - whole_number(state.def_delta, 0) <= 255
    end

    local function recover_state(state, current_resistances, legacy)
        gear_runtime.applied = {
            hp = whole_number(state.hp_delta, 0),
            mp = whole_number(state.mp_delta, 0),
            str = whole_number(state.str_delta, 0),
            def = whole_number(state.def_delta, 0),
        }
        gear_runtime.expected = {
            hp = state.expected_hp, mp = state.expected_mp,
            str = state.expected_str, def = state.expected_def,
        }
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            if legacy then
                gear_runtime.applied_resistance[element] = 0
                gear_runtime.expected_resistance[element] =
                    current_resistances[element]
            else
                gear_runtime.applied_resistance[element] =
                    tonumber(state["res_" .. element .. "_delta"]) or 0
                gear_runtime.expected_resistance[element] =
                    tonumber(state["res_" .. element .. "_expected"])
            end
        end
        local ability_id
        local ownership
        for ability_id, ownership in pairs(state.abilities or {}) do
            if ownership.slot >= 0 and ownership.slot < ABILITY_SLOT_CAPACITY
                and safe_read_byte_relative(
                    SORA_CHARACTER_BASE_RVA
                        + CHARACTER_OFFSET.ABILITIES + ownership.slot
                ) == ownership.expected then
                gear_runtime.owned_abilities[ability_id] = ownership
            end
        end
        if legacy then
            log("MIGRATED: recovered the exact Equipment Bonus v1.1 "
                .. "ownership ledger; existing bonuses will not stack.")
        else
            log("Recovered the previous equipment ownership ledger; "
                .. "bonuses will not stack after reload.")
        end
    end

    local function reset_for_loaded_save(level, experience)
        gear_runtime.applied = { hp = 0, mp = 0, str = 0, def = 0 }
        gear_runtime.expected = {
            hp = nil, mp = nil, str = nil, def = nil,
        }
        gear_runtime.applied_resistance = {
            fire = 0, ice = 0, lightning = 0, dark = 0,
        }
        gear_runtime.expected_resistance = {
            fire = nil, ice = nil, lightning = nil, dark = nil,
        }
        gear_runtime.owned_abilities = {}
        gear_runtime.signature = nil
        gear_runtime.level = level
        gear_runtime.experience = experience
        clear_state()
        log("SAVE LOAD DETECTED: discarded the old ownership ledger "
            .. "without writing to the loaded save.")
    end

    function GEAR_CONTROLLER.initialize()
        local equipment, equipment_reason = read_equipment()
        if equipment == nil then return false, equipment_reason end
        local stats, stats_reason = read_stats()
        if stats == nil then return false, stats_reason end
        local resistances, resistance_reason = read_resistances()
        if resistances == nil then return false, resistance_reason end
        local level, experience, progress_reason = read_progress()
        if level == nil then return false, progress_reason end
        local signature = equipment_signature(equipment)
        local persisted = load_state(CONFIG.EQUIPMENT_STATE_FILENAME)
        gear_runtime.signature = signature
        gear_runtime.level = level
        gear_runtime.experience = experience
        if state_matches(
            persisted, signature, stats, resistances, level, experience
        ) then
            recover_state(persisted, resistances, false)
        elseif persisted ~= nil and persisted.active == true then
            log("STATE LEDGER IGNORED: it does not exactly match the "
                .. "loaded save/equipment state.")
        else
            local legacy = load_state(
                CONFIG.LEGACY_EQUIPMENT_STATE_FILENAME
            )
            if legacy_state_matches(legacy, signature, stats) then
                recover_state(legacy, resistances, true)
            elseif legacy ~= nil and legacy.active == true then
                log("LEGACY STATE LEDGER IGNORED: Equipment Bonus v1.1's "
                    .. "ledger does not exactly match this loaded save.")
            end
        end
        gear_runtime.initialized = true
        return true, nil
    end

    function GEAR_CONTROLLER.process(force)
        if not gear_runtime.initialized then
            local ok, reason = GEAR_CONTROLLER.initialize()
            if not ok then return false, nil, nil, reason end
            force = true
        end
        local level, experience, progress_reason = read_progress()
        if level == nil then return false, nil, nil, progress_reason end
        if gear_runtime.level ~= nil and gear_runtime.experience ~= nil
            and (level < gear_runtime.level
                or experience < gear_runtime.experience) then
            reset_for_loaded_save(level, experience)
            force = true
        end
        local equipment, equipment_reason = read_equipment()
        if equipment == nil then
            return false, nil, nil, equipment_reason
        end
        local stats, stats_reason = read_stats()
        if stats == nil then return false, nil, nil, stats_reason end
        local resistances, resistance_reason = read_resistances()
        if resistances == nil then
            return false, nil, nil, resistance_reason
        end
        local signature = equipment_signature(equipment)
        local desired = calculate_desired(equipment)
        local equipment_changed = signature ~= gear_runtime.signature
        local progress_changed = level ~= gear_runtime.level
            or experience ~= gear_runtime.experience
        local stats_changed = gear_runtime.expected.hp == nil
            or stats.hp ~= gear_runtime.expected.hp
            or stats.mp ~= gear_runtime.expected.mp
            or stats.str ~= gear_runtime.expected.str
            or stats.def ~= gear_runtime.expected.def
        local resistance_changed = false
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            if gear_runtime.expected_resistance[element] == nil
                or math.abs(resistances[element]
                    - gear_runtime.expected_resistance[element])
                    > RESISTANCE_EPSILON then
                resistance_changed = true
            end
        end

        local stats_written = false
        local resistances_written = false
        local abilities_written = false
        local reason
        if force or equipment_changed or stats_changed then
            stats_written, reason = apply_stats(desired, stats)
            if reason ~= nil then return false, nil, nil, reason end
        end
        if force or equipment_changed or resistance_changed then
            resistances_written, reason = apply_resistances(
                desired, resistances
            )
            if reason ~= nil then return false, nil, nil, reason end
        end
        abilities_written, reason = update_abilities(desired.abilities)
        if reason ~= nil then return false, nil, nil, reason end

        gear_runtime.signature = signature
        gear_runtime.level = level
        gear_runtime.experience = experience
        gear_runtime.desired_limit = desired.limit
        gear_runtime.desired_risk = desired.risk

        if (force or equipment_changed)
            and CONFIG.LOG_EQUIPMENT_CHANGES then
            log("EQUIPMENT: " .. equipment_description(equipment))
            log("CUSTOM BONUS: HP=" .. tostring(desired.hp)
                .. " MP=" .. tostring(desired.mp)
                .. " STR=" .. tostring(desired.str)
                .. " DEF=" .. tostring(desired.def)
                .. "; resistance points Fire="
                .. tostring(desired.fire)
                .. " Ice=" .. tostring(desired.ice)
                .. " Lightning=" .. tostring(desired.lightning)
                .. " Dark=" .. tostring(desired.dark)
                .. "; LIMIT=" .. string.format("%+d", desired.limit)
                .. " RISK=" .. string.format("%+d", desired.risk)
                .. ".")
        end
        if force or equipment_changed or progress_changed
            or stats_written or resistances_written
            or abilities_written then
            save_state()
        end
        return true, desired, signature, nil
    end

    function GEAR_CONTROLLER.cleanup()
        if not gear_runtime.initialized then
            local ok, reason = GEAR_CONTROLLER.initialize()
            if not ok then return false, reason end
        end
        local current, stats_reason = read_stats()
        if current == nil then return false, stats_reason end
        local baseline = {
            hp = clamp(current.hp - (gear_runtime.applied.hp or 0), 1, 255),
            mp = clamp(current.mp - (gear_runtime.applied.mp or 0), 0, 255),
            str = clamp(current.str - (gear_runtime.applied.str or 0), 0, 255),
            def = clamp(current.def - (gear_runtime.applied.def or 0), 0, 255),
        }
        local hp_change = baseline.hp - current.hp
        local mp_change = baseline.mp - current.mp
        local ok
        local reason
        ok, reason = safe_write_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.MAX_HP, baseline.hp
        )
        if not ok then return false, reason end
        ok, reason = safe_write_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.MAX_MP, baseline.mp
        )
        if not ok then return false, reason end
        ok, reason = safe_write_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.STRENGTH, baseline.str
        )
        if not ok then return false, reason end
        ok, reason = safe_write_byte_relative(
            SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.DEFENSE, baseline.def
        )
        if not ok then return false, reason end
        if CONFIG.PRESERVE_MISSING_HP and current.current_hp > 0 then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_HP,
                clamp(current.current_hp + hp_change, 1, baseline.hp)
            )
            if not ok then return false, reason end
        elseif current.current_hp > baseline.hp then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_HP,
                baseline.hp
            )
            if not ok then return false, reason end
        end
        if CONFIG.PRESERVE_MISSING_MP then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_MP,
                clamp(current.current_mp + mp_change, 0, baseline.mp)
            )
            if not ok then return false, reason end
        elseif current.current_mp > baseline.mp then
            ok, reason = safe_write_byte_relative(
                SORA_CHARACTER_BASE_RVA + CHARACTER_OFFSET.CURRENT_MP,
                baseline.mp
            )
            if not ok then return false, reason end
        end

        local resistances, resistance_reason = read_resistances()
        if resistances == nil then return false, resistance_reason end
        local index
        for index = 1, #ELEMENTS do
            local element = ELEMENTS[index]
            local expected = gear_runtime.expected_resistance[element]
            if expected ~= nil
                and math.abs(resistances[element] - expected)
                    <= RESISTANCE_EPSILON then
                ok, reason = safe_write_float_relative(
                    SORA_RESISTANCE_RVA + RESISTANCE_OFFSET[element],
                    resistances[element]
                        - (gear_runtime.applied_resistance[element] or 0)
                )
                if not ok then return false, reason end
            end
        end

        local owned_ids = {}
        local ability_id
        local ownership
        for ability_id, ownership in pairs(
            gear_runtime.owned_abilities
        ) do
            owned_ids[#owned_ids + 1] = ability_id
        end
        for index = 1, #owned_ids do
            ability_id = owned_ids[index]
            ownership = gear_runtime.owned_abilities[ability_id]
            if ownership ~= nil then
                ok, reason = release_owned_ability(ability_id, ownership)
                if not ok then return false, reason end
            end
        end
        gear_runtime.applied = { hp = 0, mp = 0, str = 0, def = 0 }
        gear_runtime.applied_resistance = {
            fire = 0, ice = 0, lightning = 0, dark = 0,
        }
        clear_state()
        log("CLEANUP COMPLETE: every still-owned equipment stat, "
            .. "resistance, and ability change was restored.")
        return true, nil
    end
end

local function refresh_equipment_modifiers(force_log)
    local equipment_ok, desired, signature, reason =
        GEAR_CONTROLLER.process(force_log)
    if not equipment_ok then
        return false, reason
    end
    local restore_modifier = clamp_modifier(
        (tonumber(CONFIG.INITIAL_EQUIPMENT_RESTORE_MODIFIER) or 0)
            + desired.limit
    )
    local loss_modifier = clamp_modifier(
        (tonumber(CONFIG.INITIAL_EQUIPMENT_LOSS_MODIFIER) or 0)
            + desired.risk
    )

    if restore_modifier ~= runtime.last_restore_modifier then
        local ok, write_reason = safe_write_int(
            LIMIT_RESTORE_MODIFIER_RVA,
            restore_modifier
        )
        if not ok then
            return false, "restoration modifier write failed: "
                .. tostring(write_reason)
        end
    end
    if loss_modifier ~= runtime.last_loss_modifier then
        local ok, write_reason = safe_write_int(
            LIMIT_LOSS_MODIFIER_RVA,
            loss_modifier
        )
        if not ok then
            return false, "hit-loss modifier write failed: "
                .. tostring(write_reason)
        end
    end

    local changed = restore_modifier ~= runtime.last_restore_modifier
        or loss_modifier ~= runtime.last_loss_modifier
        or signature ~= runtime.last_equipment_signature
    runtime.last_restore_modifier = restore_modifier
    runtime.last_loss_modifier = loss_modifier
    runtime.last_equipment_signature = signature

    if CONFIG.LOG_EQUIPMENT_CHANGES ~= false
        and (force_log or changed) then
        local effective_restore = effective_limit_amount(
            LIMIT_RESTORE_BASE, restore_modifier
        )
        local effective_loss = effective_limit_amount(
            LIMIT_LOSS_PER_HIT_BASE, loss_modifier
        )
        log("EQUIPMENT: " .. tostring(signature)
            .. "; restoration=" .. tostring(LIMIT_RESTORE_BASE)
            .. string.format("%+d", restore_modifier)
            .. " -> " .. tostring(effective_restore)
            .. "; hit loss=" .. tostring(LIMIT_LOSS_PER_HIT_BASE)
            .. string.format("%+d", loss_modifier)
            .. " -> " .. tostring(effective_loss)
            .. ".")
    end
    return true, nil
end

local function append_u32(bytes, value)
    local number = math.floor(value) % 4294967296
    bytes[#bytes + 1] = number % 256
    number = math.floor(number / 256)
    bytes[#bytes + 1] = number % 256
    number = math.floor(number / 256)
    bytes[#bytes + 1] = number % 256
    number = math.floor(number / 256)
    bytes[#bytes + 1] = number % 256
end

local function make_branch(opcode, source_rva, target_rva)
    local bytes = { opcode }
    append_u32(bytes, target_rva - (source_rva + 5))
    return bytes
end

local NOP_FIVE = { 0x90, 0x90, 0x90, 0x90, 0x90 }

local damage_finalize_custom = make_branch(
    0xE8,
    DAMAGE_FINALIZE_SITE_RVA,
    DAMAGE_FINALIZE_WRAPPER_RVA
)
damage_finalize_custom[#damage_finalize_custom + 1] = 0x90
damage_finalize_custom[#damage_finalize_custom + 1] = 0x90
damage_finalize_custom[#damage_finalize_custom + 1] = 0x90

local outgoing_damage_custom = make_branch(
    0xE8,
    DAMAGE_FORMULA_CALL_RVA,
    OUTGOING_DAMAGE_WRAPPER_RVA
)

local OWNED_PATCHES = {
    {
        rva = TECH_POPUP_SITE_A_RVA,
        original = TECH_POPUP_SITE_A_ORIGINAL,
        custom = NOP_FIVE,
        name = "Tech popup A suppression",
    },
    {
        rva = TECH_AWARD_SITE_A_RVA,
        original = TECH_AWARD_SITE_A_ORIGINAL,
        custom = make_branch(
            0xE8,
            TECH_AWARD_SITE_A_RVA,
            TECH_AWARD_WRAPPER_RVA
        ),
        name = "Tech EXP A to LIMIT redirect",
    },
    {
        rva = TECH_POPUP_SITE_B_RVA,
        original = TECH_POPUP_SITE_B_ORIGINAL,
        custom = NOP_FIVE,
        name = "Tech popup B suppression",
    },
    {
        rva = TECH_AWARD_SITE_B_RVA,
        original = TECH_AWARD_SITE_B_ORIGINAL,
        custom = make_branch(
            0xE9,
            TECH_AWARD_SITE_B_RVA,
            TECH_AWARD_WRAPPER_RVA
        ),
        name = "Tech EXP B to LIMIT redirect",
    },
    {
        rva = TECH_POPUP_SITE_C_RVA,
        original = TECH_POPUP_SITE_C_ORIGINAL,
        custom = NOP_FIVE,
        name = "Tech popup C suppression",
    },
    {
        rva = TECH_AWARD_SITE_C_RVA,
        original = TECH_AWARD_SITE_C_ORIGINAL,
        custom = make_branch(
            0xE8,
            TECH_AWARD_SITE_C_RVA,
            TECH_AWARD_WRAPPER_RVA
        ),
        name = "Tech EXP C to LIMIT redirect",
    },
    {
        rva = DAMAGE_FINALIZE_SITE_RVA,
        original = DAMAGE_FINALIZE_ORIGINAL_BYTES,
        custom = damage_finalize_custom,
        name = "post-EnemyConfig finalized-damage hook",
    },
    {
        rva = DAMAGE_FORMULA_CALL_RVA,
        original = DAMAGE_FORMULA_CALL_ORIGINAL,
        custom = outgoing_damage_custom,
        name = "Sora-owned attack/spell damage formula hook",
    },
}

local function build_is_exact()
    local ok, value = pcall(ReadLong, VERSION_SENTINEL_RVA, false)
    return ok and value == VERSION_VALUE
end

local function character_is_ready()
    local ok_level, level = pcall(
        ReadByte,
        SORA_CHARACTER_BASE_RVA,
        false
    )
    local ok_hp, maximum_hp = pcall(
        ReadByte,
        SORA_CHARACTER_BASE_RVA + 0x02,
        false
    )
    return ok_level and ok_hp
        and level ~= nil and maximum_hp ~= nil
        and level >= 1 and level <= 100
        and maximum_hp >= 1
end

local function verify_native_signatures()
    local index
    for index = 1, #NATIVE_SIGNATURES do
        local signature = NATIVE_SIGNATURES[index]
        local actual = safe_read_array(signature.rva, #signature.bytes)
        if not arrays_equal(actual, signature.bytes) then
            return false, signature.name .. " signature mismatch"
        end
    end

    local enemy_hook = safe_read_array(
        ENEMY_CONFIG_HOOK_RVA,
        #ENEMY_CONFIG_NATIVE_BYTES
    )
    if not arrays_equal(enemy_hook, ENEMY_CONFIG_NATIVE_BYTES)
        and not arrays_equal(enemy_hook, ENEMY_CONFIG_V2_BYTES) then
        return false, "KHFM_EnemyConfig damage-hook site is incompatible"
    end
    return true
end

local function patch_state()
    local original_count = 0
    local custom_count = 0
    local legacy_without_output = true
    local index
    for index = 1, #OWNED_PATCHES do
        local patch = OWNED_PATCHES[index]
        local actual = safe_read_array(patch.rva, #patch.original)
        if arrays_equal(actual, patch.original) then
            original_count = original_count + 1
            if index < #OWNED_PATCHES then
                legacy_without_output = false
            end
        elseif arrays_equal(actual, patch.custom) then
            custom_count = custom_count + 1
            if index == #OWNED_PATCHES then
                legacy_without_output = false
            end
        else
            return nil, patch.name .. " contains unknown bytes"
        end
    end
    if original_count == #OWNED_PATCHES then
        return "native"
    end
    if custom_count == #OWNED_PATCHES then
        return "installed"
    end
    if legacy_without_output then
        return "legacy_without_output"
    end
    return nil, "LIMIT patches are only partially installed"
end

local function cave_state()
    local static = safe_read_array(CAVE_RVA, CAVE_STATIC_SIZE)
    if arrays_equal_prefix(static, CAVE_IMAGE, CAVE_STATIC_SIZE) then
        local outgoing_code = safe_read_array(
            CAVE_RVA + OUTGOING_CODE_OFFSET,
            OUTGOING_CODE_SIZE
        )
        local outgoing_matches = outgoing_code ~= nil
        local index
        if outgoing_matches then
            for index = 1, OUTGOING_CODE_SIZE do
                if outgoing_code[index]
                    ~= CAVE_IMAGE[OUTGOING_CODE_OFFSET + index] then
                    outgoing_matches = false
                    break
                end
            end
        end
        if outgoing_matches then
            return "installed"
        end

        if arrays_equal(
            outgoing_code,
            LEGACY_V1_5_OUTGOING_CODE
        ) then
            return "legacy_v1_5"
        end

        -- V1.3 owns the same first 0xA0 bytes and uses mutable data only
        -- through +0xC7. Its entire outgoing-code tail is therefore zero.
        local legacy_tail = safe_read_array(
            CAVE_RVA + 0xC8,
            CAVE_REGION_SIZE - 0xC8
        )
        if is_zero_array(legacy_tail) then
            return "legacy_v1_3"
        end
        return nil, "private LIMIT outgoing region contains unknown bytes"
    end

    local legacy_static = safe_read_array(
        CAVE_RVA,
        LEGACY_CAVE_STATIC_SIZE
    )
    if arrays_equal(
        legacy_static,
        LEGACY_V1_2_CAVE_STATIC
    ) then
        return "legacy_v1_2"
    end
    if arrays_equal_prefix(
        legacy_static,
        LEGACY_V1_1_CAVE_STATIC,
        LEGACY_CAVE_STATIC_SIZE
    ) then
        return "legacy_v1_1"
    end
    if arrays_equal_prefix(
        legacy_static,
        LEGACY_V1_CAVE_STATIC,
        LEGACY_CAVE_STATIC_SIZE
    ) then
        return "legacy_v1"
    end
    local region = safe_read_array(CAVE_RVA, CAVE_REGION_SIZE)
    if is_zero_array(region) then
        return "empty"
    end
    return nil, "private LIMIT region is neither empty nor owned"
end

local function clear_cave()
    local zeros = {}
    local index
    for index = 1, CAVE_REGION_SIZE do
        zeros[index] = 0
    end
    return safe_write_array(CAVE_RVA, zeros)
end

local function detach_enemy_limit_hook()
    local actual = safe_read_array(
        ENEMY_HOOK_CODE_RVA,
        #ENEMY_LIMIT_CODE_BYTES
    )
    if arrays_equal(actual, ENEMY_LIMIT_CODE_BYTES) then
        return safe_write_array(
            ENEMY_HOOK_CODE_RVA,
            ENEMY_BASELINE_CODE_BYTES
        )
    end
    if arrays_equal(actual, ENEMY_BASELINE_CODE_BYTES) then
        return true
    end
    -- Any other prefix does not match the only companion branch that targets
    -- this LIMIT cave, so it does not need to be changed before cleanup.
    return true
end

local function restore_owned_patches()
    local index
    for index = #OWNED_PATCHES, 1, -1 do
        local patch = OWNED_PATCHES[index]
        local actual = safe_read_array(patch.rva, #patch.custom)
        if arrays_equal(actual, patch.custom) then
            local ok, reason = safe_write_array(patch.rva, patch.original)
            if not ok then
                return false, patch.name .. " restore failed: "
                    .. tostring(reason)
            end
        elseif not arrays_equal(actual, patch.original) then
            return false, patch.name .. " cannot be restored safely"
        end
    end
    return true
end

local function rollback_fresh_install()
    restore_owned_patches()
    local static = safe_read_array(CAVE_RVA, CAVE_STATIC_SIZE)
    if arrays_equal_prefix(static, CAVE_IMAGE, CAVE_STATIC_SIZE) then
        clear_cave()
    end
end

local function install_hooks()
    local patches, patch_reason = patch_state()
    if patches == nil then
        return false, patch_reason
    end
    local cave, cave_reason = cave_state()
    if cave == nil then
        return false, cave_reason
    end

    if patches == "installed"
        and cave ~= "installed"
        and cave ~= "legacy_v1_5" then
        return false, "installed LIMIT branches have no owned code image"
    end
    if patches == "legacy_without_output"
        and cave ~= "legacy_v1_3"
        and cave ~= "legacy_v1_2"
        and cave ~= "legacy_v1_1"
        and cave ~= "legacy_v1" then
        return false, "legacy LIMIT branches have no recognized code image"
    end
    if patches == "native" and cave == "installed" then
        return false, "owned LIMIT code exists without its native branches"
    end

    if patches == "installed" and cave == "installed" then
        return true, "reused the existing verified LIMIT hook", "reused"
    end

    if patches == "installed" and cave == "legacy_v1_5" then
        local legacy_limit = clamp_limit(
            safe_read_int(LIMIT_VALUE_RVA) or 0
        )
        local upgraded, upgrade_reason = safe_write_array(
            CAVE_RVA,
            CAVE_IMAGE
        )
        if not upgraded then
            return false, "v1.5 outgoing-order upgrade failed: "
                .. tostring(upgrade_reason)
        end
        local limit_ok, limit_reason = safe_write_int(
            LIMIT_VALUE_RVA,
            legacy_limit
        )
        if not limit_ok then
            return false, "v1.5 LIMIT preservation failed: "
                .. tostring(limit_reason)
        end
        return true, "upgraded the exact v1.5 hook while preserving LIMIT",
            "upgraded"
    end

    if patches == "legacy_without_output"
        and (cave == "legacy_v1_3"
            or cave == "legacy_v1_2"
            or cave == "legacy_v1_1"
            or cave == "legacy_v1") then
        local legacy_limit_rva = CAVE_RVA + 0x70
        if cave == "legacy_v1_3" then
            legacy_limit_rva = LIMIT_VALUE_RVA
        end
        local legacy_limit = clamp_limit(
            safe_read_int(legacy_limit_rva) or 0
        )
        local upgraded, upgrade_reason = safe_write_array(
            CAVE_RVA,
            CAVE_IMAGE
        )
        if not upgraded then
            return false, "legacy code upgrade failed: "
                .. tostring(upgrade_reason)
        end
        local limit_ok, limit_reason = safe_write_int(
            LIMIT_VALUE_RVA,
            legacy_limit
        )
        if not limit_ok then
            return false, "legacy LIMIT migration failed: "
                .. tostring(limit_reason)
        end
        local outgoing_patch = OWNED_PATCHES[#OWNED_PATCHES]
        local outgoing_ok, outgoing_reason = safe_write_array(
            outgoing_patch.rva,
            outgoing_patch.custom
        )
        if not outgoing_ok then
            return false, "outgoing-damage hook upgrade failed: "
                .. tostring(outgoing_reason)
        end
        local source_version = "v1"
        if cave == "legacy_v1_3" then
            source_version = "v1.3"
        elseif cave == "legacy_v1_2" then
            source_version = "v1.2"
        elseif cave == "legacy_v1_1" then
            source_version = "v1.1"
        end
        return true, "upgraded the exact " .. source_version
            .. " hook while preserving LIMIT", "upgraded"
    end

    local cave_ok, cave_write_reason = safe_write_array(CAVE_RVA, CAVE_IMAGE)
    if not cave_ok then
        return false, "private LIMIT code install failed: "
            .. tostring(cave_write_reason)
    end

    local index
    for index = 1, #OWNED_PATCHES do
        local patch = OWNED_PATCHES[index]
        local ok, reason = safe_write_array(patch.rva, patch.custom)
        if not ok then
            rollback_fresh_install()
            return false, patch.name .. " install failed: " .. tostring(reason)
        end
    end
    return true, "installed the confirmed-block, incoming-damage, and "
        .. "Sora outgoing-damage hooks", "fresh"
end

local function resolve_state_path()
    if not CONFIG.PERSIST_BETWEEN_SESSIONS
        or io == nil or io.open == nil
        or SCRIPT_PATH == nil then
        return nil
    end
    local separator = "\\"
    if package ~= nil and package.config ~= nil then
        separator = string.sub(package.config, 1, 1)
    end
    return SCRIPT_PATH .. separator .. CONFIG.STATE_FILENAME
end

local function load_persisted_limit()
    local fallback = clamp_limit(CONFIG.STARTING_LIMIT_WITHOUT_STATE)
    runtime.state_path = resolve_state_path()
    if runtime.state_path == nil then
        return fallback, false, "persistence unavailable; using runtime LIMIT"
    end

    local file = io.open(runtime.state_path, "r")
    if file == nil then
        runtime.persistence_available = true
        return fallback, false, "no prior state; starting at "
            .. tostring(fallback)
    end
    local content = file:read("*a") or ""
    file:close()
    local value = string.match(content, "LIMIT%s*=%s*(-?%d+)")
    if value == nil then
        runtime.persistence_available = true
        return fallback, false, "state was malformed; starting at "
            .. tostring(fallback)
    end
    runtime.persistence_available = true
    return clamp_limit(value), true, "restored persistent LIMIT"
end

local function save_persisted_limit(value)
    if not CONFIG.PERSIST_BETWEEN_SESSIONS
        or not runtime.persistence_available
        or runtime.state_path == nil then
        return true
    end
    local file = io.open(runtime.state_path, "w")
    if file == nil then
        return false, "state file could not be opened"
    end
    file:write("KH1FM_LIMIT_STATE_V1\n")
    file:write("LIMIT=", tostring(clamp_limit(value)), "\n")
    file:close()
    return true
end

local function flush_pending_persistence(force)
    if not runtime.persistence_dirty then
        return true
    end
    if not CONFIG.PERSIST_BETWEEN_SESSIONS
        or not runtime.persistence_available
        or runtime.state_path == nil then
        runtime.persistence_dirty = false
        return true
    end
    if not force
        and runtime.frame - runtime.last_persistence_save_frame
            < runtime.persistence_interval_frames then
        return true
    end

    local saved, reason = save_persisted_limit(
        runtime.pending_persisted_limit
    )
    if not saved then
        return false, reason
    end
    runtime.persistence_dirty = false
    runtime.last_persistence_save_frame = runtime.frame
    runtime.summary.persistence_writes =
        runtime.summary.persistence_writes + 1
    return true
end

local function reset_summary_counters()
    runtime.summary.defense_events = 0
    runtime.summary.limit_restored = 0
    runtime.summary.damaging_hits = 0
    runtime.summary.protected_hits = 0
    runtime.summary.outgoing_hits = 0
    runtime.summary.rejected_candidates = 0
    runtime.summary.persistence_writes = 0
    runtime.summary.risk_limit_generated = 0
end

local function maybe_log_periodic_summary(limit)
    if not CONFIG.LOG_PERIODIC_SUMMARY
        or runtime.frame - runtime.last_summary_frame
            < runtime.summary_interval_frames then
        return
    end

    runtime.last_summary_frame = runtime.frame
    local summary = runtime.summary
    local activity = summary.defense_events
        + summary.damaging_hits
        + summary.outgoing_hits
        + summary.rejected_candidates
        + summary.persistence_writes
        + summary.risk_limit_generated
    if activity > 0 then
        log("SUMMARY: defenses=" .. tostring(summary.defense_events)
            .. " (" .. string.format("%+d", summary.limit_restored)
            .. " net LIMIT); Sora hits="
            .. tostring(summary.damaging_hits)
            .. " (" .. tostring(summary.protected_hits)
            .. " protected); Sora output hits="
            .. tostring(summary.outgoing_hits)
            .. "; inverted-RISK gain="
            .. tostring(summary.risk_limit_generated)
            .. "; rejected projectile candidates="
            .. tostring(summary.rejected_candidates)
            .. "; state writes="
            .. tostring(summary.persistence_writes)
            .. "; LIMIT=" .. tostring(clamp_limit(limit))
            .. "/" .. tostring(MAX_LIMIT) .. ".")
    end
    reset_summary_counters()
end

local function unsigned_sequence_delta(current, previous)
    if current >= previous then
        return current - previous
    end
    return (4294967296 - previous) + current
end

local function queue_tech_candidates(count)
    if count <= 0 then
        return
    end
    runtime.pending_tech_candidates[
        #runtime.pending_tech_candidates + 1
    ] = {
        count = count,
        frame = runtime.frame,
    }
end

local function consume_recent_tech_candidates(requested)
    local remaining = requested
    local consumed = 0
    local index = #runtime.pending_tech_candidates
    while index >= 1 and remaining > 0 do
        local batch = runtime.pending_tech_candidates[index]
        local age = runtime.frame - batch.frame
        if age <= CONFIG.TECH_CANDIDATE_DAMAGE_WINDOW_FRAMES then
            local take = math.min(batch.count, remaining)
            batch.count = batch.count - take
            remaining = remaining - take
            consumed = consumed + take
            if batch.count <= 0 then
                table.remove(runtime.pending_tech_candidates, index)
            end
        end
        index = index - 1
    end
    return consumed
end

local function award_limit(source)
    local current = safe_read_int(LIMIT_VALUE_RVA)
    if current == nil then
        return false, "LIMIT value became unreadable"
    end
    local restore_modifier = safe_read_signed_int(
        LIMIT_RESTORE_MODIFIER_RVA
    )
    if restore_modifier == nil then
        return false, "equipment restoration modifier became unreadable"
    end
    local change_amount = effective_limit_amount(
        LIMIT_RESTORE_BASE,
        restore_modifier
    )
    current = clamp_limit(current)
    local updated = clamp_limit(current + change_amount)
    local write_ok, write_reason = safe_write_int(
        LIMIT_VALUE_RVA,
        updated
    )
    if not write_ok then
        return false, tostring(write_reason)
    end
    runtime.summary.defense_events =
        runtime.summary.defense_events + 1
    runtime.summary.limit_restored =
        runtime.summary.limit_restored + (updated - current)
    if debug_enabled(CONFIG.LOG_EACH_EVENT) then
        log("BLOCK/DEFLECT: " .. tostring(source)
            .. "; LIMIT changed by "
            .. string.format("%+d", change_amount)
            .. " (base " .. tostring(LIMIT_RESTORE_BASE)
            .. ", equipment modifier "
            .. string.format("%+d", restore_modifier)
            .. "); LIMIT=" .. tostring(updated) .. "/"
            .. tostring(MAX_LIMIT) .. "; native Tech EXP=0.")
    end
    return true
end

local function apply_inverted_risk(damage_events)
    if damage_events <= 0 then
        return true, nil
    end
    local loss_modifier = safe_read_signed_int(
        LIMIT_LOSS_MODIFIER_RVA
    )
    if loss_modifier == nil then
        return false, "equipment RISK modifier became unreadable"
    end
    local effective_loss = effective_limit_amount(
        LIMIT_LOSS_PER_HIT_BASE,
        loss_modifier
    )
    if effective_loss >= 0 then
        return true, nil
    end
    local current = safe_read_int(LIMIT_VALUE_RVA)
    if current == nil then
        return false, "LIMIT value became unreadable during RISK inversion"
    end
    current = clamp_limit(current)
    local requested_gain = -effective_loss * damage_events
    local updated = clamp_limit(current + requested_gain)
    local ok, reason = safe_write_int(LIMIT_VALUE_RVA, updated)
    if not ok then
        return false, tostring(reason)
    end
    local actual_gain = updated - current
    runtime.summary.risk_limit_generated =
        runtime.summary.risk_limit_generated + actual_gain
    if debug_enabled(CONFIG.LOG_EACH_EVENT) then
        log("RISK INVERTED: " .. tostring(damage_events)
            .. " damaging hit(s) generated " .. tostring(actual_gain)
            .. " LIMIT (" .. tostring(-effective_loss)
            .. " requested per hit); LIMIT=" .. tostring(updated)
            .. "/" .. tostring(MAX_LIMIT) .. ".")
    end
    return true, updated
end

local function flush_confirmed_projectile_candidates()
    local index = 1
    while index <= #runtime.pending_tech_candidates do
        local batch = runtime.pending_tech_candidates[index]
        local age = runtime.frame - batch.frame
        if age > CONFIG.TECH_CANDIDATE_DAMAGE_WINDOW_FRAMES then
            local count = batch.count
            table.remove(runtime.pending_tech_candidates, index)
            local event_index
            for event_index = 1, count do
                local ok, reason = award_limit(
                    "projectile deflection confirmed without Sora damage"
                )
                if not ok then
                    return false, reason
                end
            end
        else
            index = index + 1
        end
    end
    return true
end

local function read_sora_motion(sora)
    if sora == nil or sora == 0 then
        return nil, nil
    end
    local animation = safe_read_byte_absolute(
        sora + SORA_CURRENT_ANIMATION_OFFSET
    )
    local animation_time = safe_read_float_absolute(
        sora + SORA_ANIMATION_TIME_OFFSET
    )
    return animation, animation_time
end

local function reset_sora_motion_observation(sora)
    runtime.previous_animation, runtime.previous_animation_time =
        read_sora_motion(sora)
end

local function detect_parry_reaction(sora)
    local animation, animation_time = read_sora_motion(sora)
    if animation == nil then
        return nil, nil
    end

    local parry_name = PARRY_ANIMATIONS[animation]
    local previous_parry = PARRY_ANIMATIONS[runtime.previous_animation]
    local restarted = false
    if parry_name ~= nil
        and previous_parry ~= nil
        and runtime.previous_animation == animation
        and animation_time ~= nil
        and runtime.previous_animation_time ~= nil
        and animation_time + 0.25 < runtime.previous_animation_time then
        restarted = true
    end

    local entered = parry_name ~= nil
        and (previous_parry == nil
            or runtime.previous_animation ~= animation
            or restarted)

    runtime.previous_animation = animation
    runtime.previous_animation_time = animation_time

    if entered then
        return animation, parry_name
    end
    return nil, nil
end

local function initialize_runtime()
    local signatures_ok, signature_reason = verify_native_signatures()
    if not signatures_ok then
        return false, signature_reason
    end

    local gear_ok, gear_reason = GEAR_CONTROLLER.initialize()
    if not gear_ok then
        return false, "equipment ownership initialization failed: "
            .. tostring(gear_reason)
    end

    if not CONFIG.ENABLE then
        local cleanup_ok, cleanup_reason = GEAR_CONTROLLER.cleanup()
        if not cleanup_ok then
            return false, "equipment cleanup failed: "
                .. tostring(cleanup_reason)
        end
        local patches, patch_reason = patch_state()
        if patches == nil then
            return false, patch_reason
        end
        if patches == "installed"
            or patches == "legacy_without_output" then
            local cave, cave_reason = cave_state()
            if cave ~= "installed"
                and cave ~= "legacy_v1_5"
                and cave ~= "legacy_v1_3"
                and cave ~= "legacy_v1_2"
                and cave ~= "legacy_v1_1"
                and cave ~= "legacy_v1" then
                return false, cave_reason
            end
            local current_limit_rva = LIMIT_VALUE_RVA
            if cave ~= "installed"
                and cave ~= "legacy_v1_5"
                and cave ~= "legacy_v1_3" then
                current_limit_rva = CAVE_RVA + 0x70
            end
            local current_limit = safe_read_int(current_limit_rva)
            if current_limit ~= nil then
                runtime.state_path = resolve_state_path()
                runtime.persistence_available = runtime.state_path ~= nil
                save_persisted_limit(clamp_limit(current_limit))
            end
            local detach_ok, detach_reason = detach_enemy_limit_hook()
            if not detach_ok then
                return false, "companion damage-order detach failed: "
                    .. tostring(detach_reason)
            end
            local restore_ok, restore_reason = restore_owned_patches()
            if not restore_ok then
                return false, restore_reason
            end
            local clear_ok, clear_reason = clear_cave()
            if not clear_ok then
                return false, "private region clear failed: "
                    .. tostring(clear_reason)
            end
        end
        runtime.stopped = true
        log("DISABLED: equipment changes, native Tech EXP, Tech popup, "
            .. "and damage code were restored. Save before removing this Lua.")
        return true
    end

    local install_ok, install_reason, install_mode = install_hooks()
    if not install_ok then
        return false, install_reason
    end
    if safe_read_int(LIMIT_INTERFACE_SENTINEL_RVA)
        ~= LIMIT_INTERFACE_SENTINEL then
        return false, "LIMIT/EnemyConfig shared-order interface is missing"
    end

    local limit
    local restored
    local persistence_reason
    if install_mode == "fresh" then
        limit, restored, persistence_reason = load_persisted_limit()
    else
        limit = clamp_limit(safe_read_int(LIMIT_VALUE_RVA))
        restored = true
        runtime.state_path = resolve_state_path()
        runtime.persistence_available = runtime.state_path ~= nil
        persistence_reason = "preserved runtime LIMIT during "
            .. tostring(install_mode)
    end
    local limit_ok, limit_reason = safe_write_int(LIMIT_VALUE_RVA, limit)
    if not limit_ok then
        return false, "initial LIMIT write failed: " .. tostring(limit_reason)
    end

    runtime.last_restore_modifier = nil
    runtime.last_loss_modifier = nil
    runtime.last_equipment_signature = nil
    local equipment_ok, equipment_reason =
        refresh_equipment_modifiers(true)
    if not equipment_ok then
        return false, "initial equipment scan failed: "
            .. tostring(equipment_reason)
    end
    local restore_modifier = runtime.last_restore_modifier
    local loss_modifier = runtime.last_loss_modifier

    local effective_restore = effective_limit_amount(
        LIMIT_RESTORE_BASE,
        restore_modifier
    )
    local effective_loss = effective_limit_amount(
        LIMIT_LOSS_PER_HIT_BASE,
        loss_modifier
    )

    local sora = safe_read_long(SORA_POINTER_RVA) or 0
    local sora_ok, sora_reason = safe_write_long(
        CAVE_SORA_POINTER_RVA,
        sora
    )
    if not sora_ok then
        return false, "initial Sora pointer failed: " .. tostring(sora_reason)
    end

    runtime.last_limit = limit
    runtime.last_tech_candidate_sequence =
        safe_read_int(TECH_CANDIDATE_SEQUENCE_RVA) or 0
    runtime.last_damage_sequence = safe_read_int(DAMAGE_SEQUENCE_RVA) or 0
    runtime.last_protected_damage_sequence =
        safe_read_int(PROTECTED_DAMAGE_SEQUENCE_RVA) or 0
    runtime.last_outgoing_damage_sequence =
        safe_read_int(OUTGOING_DAMAGE_SEQUENCE_RVA) or 0
    runtime.last_sora = sora
    runtime.frame = 0
    runtime.cached_hertz = read_runtime_hertz()
    runtime.persistence_interval_frames = seconds_to_frames(
        CONFIG.PERSISTENCE_WRITE_INTERVAL_SECONDS,
        runtime.cached_hertz
    )
    runtime.last_persistence_save_frame = 0
    runtime.persistence_dirty = install_mode ~= "fresh"
    runtime.pending_persisted_limit = limit
    runtime.summary_interval_frames = seconds_to_frames(
        CONFIG.SUMMARY_INTERVAL_SECONDS,
        runtime.cached_hertz
    )
    runtime.last_summary_frame = 0
    reset_summary_counters()
    runtime.pending_tech_candidates = {}
    runtime.parry_dedupe_frame = -1000
    runtime.parry_dedupe_credit = 0
    reset_sora_motion_observation(sora)
    runtime.initialized = true

    if runtime.persistence_available and not restored then
        local saved, save_reason = save_persisted_limit(limit)
        if not saved then
            log("PERSISTENCE WARNING: " .. tostring(save_reason))
            runtime.persistence_available = false
        else
            runtime.last_persistence_save_frame = runtime.frame
        end
    end

    log("READY: " .. install_reason .. ".")
    log("BLOCK DETECTOR: Sora parry reactions 0x6E/0x6F change LIMIT by "
        .. string.format("%+d", effective_restore) .. " (base "
        .. tostring(LIMIT_RESTORE_BASE) .. ", equipment modifier "
        .. string.format("%+d", restore_modifier)
        .. "); projectile Tech paths are damage-checked candidates.")
    log("TECH: native Tech EXP and Tech popup are suppressed; a candidate "
        .. "that coincides with Sora damage awards no LIMIT.")
    log("DAMAGE: with LIMIT>0, Sora takes 80% of finalized integer damage; "
        .. "each damaging hit changes LIMIT by "
        .. string.format("%+d", -effective_loss)
        .. " (base loss " .. tostring(LIMIT_LOSS_PER_HIT_BASE)
        .. ", equipment modifier " .. string.format("%+d", loss_modifier)
        .. ").")
    log("OUTPUT: every " .. tostring(LIMIT_POINTS_PER_DAMAGE_TIER)
        .. " LIMIT adds "
        .. tostring(LIMIT_DAMAGE_BONUS_PERCENT_PER_TIER)
        .. "% to Sora-owned melee, magic, ability, and projectile damage; "
        .. "100 LIMIT = "
        .. tostring(100 + LIMIT_MAX_DAMAGE_TIERS
            * LIMIT_DAMAGE_BONUS_PERCENT_PER_TIER)
        .. "% total.")
    log("ORDER: native formula -> KHFM_EnemyConfig DAMAGE_TAKEN -> "
        .. "LIMIT output tier -> DAMAGE_FLOOR/DAMAGE_CEILING -> "
        .. "HP subtraction.")
    log("COMPANION: KHFM_EnemyConfig v4.4.31 consumes the Sora-owned "
        .. "one-hit marker through helper RVA="
        .. string.format("0x%X", LIMIT_POST_MULTIPLIER_HELPER_RVA)
        .. ".")
    log("EQUIPMENT: restoration modifier RVA="
        .. string.format("0x%X", EQUIPMENT_INTERFACE.RESTORE_MODIFIER_RVA)
        .. "; hit-loss modifier RVA="
        .. string.format("0x%X", EQUIPMENT_INTERFACE.LOSS_MODIFIER_RVA)
        .. "; signed additive values, module-relative.")
    log("STATE: LIMIT=" .. tostring(limit) .. "/"
        .. tostring(MAX_LIMIT) .. "; " .. persistence_reason .. ".")
    log("STABILITY: detailed event logs="
        .. tostring(CONFIG.DEBUG_MODE == true)
        .. "; pending state is written no more than once every "
        .. tostring(CONFIG.PERSISTENCE_WRITE_INTERVAL_SECONDS)
        .. " second(s); activity summary interval="
        .. tostring(CONFIG.SUMMARY_INTERVAL_SECONDS) .. " second(s).")
    log("HUD: NumericHudV1.9 remains isolated; custom LIMIT gauge is not "
        .. "drawn by this core test.")
    return true
end

local function update_runtime()
    runtime.frame = runtime.frame + 1

    -- A valid marker is normally produced and consumed inside one native
    -- damage call. Clear any unconsumed prior-frame marker so a later
    -- party-member hit can never inherit Sora's LIMIT tier.
    local marker_ok, marker_reason = safe_write_long(
        LIMIT_PENDING_TARGET_RVA,
        0
    )
    if not marker_ok then
        runtime.stopped = true
        log("STOPPED: stale outgoing marker clear failed: "
            .. tostring(marker_reason))
        return
    end

    local sora = safe_read_long(SORA_POINTER_RVA) or 0
    if sora ~= runtime.last_sora then
        if CONFIG.FORCE_SAVE_ON_SORA_POINTER_CHANGE then
            local saved, save_reason = flush_pending_persistence(true)
            if not saved then
                log("PERSISTENCE WARNING: transition flush failed: "
                    .. tostring(save_reason))
                runtime.persistence_available = false
            end
        end
        local pointer_ok, pointer_reason = safe_write_long(
            CAVE_SORA_POINTER_RVA,
            sora
        )
        if not pointer_ok then
            runtime.stopped = true
            log("STOPPED: Sora pointer update failed: "
                .. tostring(pointer_reason))
            return
        end
        runtime.last_sora = sora
        runtime.pending_tech_candidates = {}
        runtime.parry_dedupe_frame = -1000
        runtime.parry_dedupe_credit = 0
        reset_sora_motion_observation(sora)
    end

    local equipment_interval = math.max(1, math.floor(
        tonumber(CONFIG.UPDATE_EQUIPMENT_EVERY_N_FRAMES) or 10
    ))
    if runtime.frame % equipment_interval == 0 then
        local equipment_ok, equipment_reason =
            refresh_equipment_modifiers(false)
        if not equipment_ok then
            runtime.stopped = true
            log("STOPPED: equipment modifier update failed: "
                .. tostring(equipment_reason))
            return
        end
    end

    local limit = safe_read_int(LIMIT_VALUE_RVA)
    local tech_candidate_sequence = safe_read_int(
        TECH_CANDIDATE_SEQUENCE_RVA
    )
    local damage_sequence = safe_read_int(DAMAGE_SEQUENCE_RVA)
    local protected_damage_sequence = safe_read_int(
        PROTECTED_DAMAGE_SEQUENCE_RVA
    )
    local outgoing_damage_sequence = safe_read_int(
        OUTGOING_DAMAGE_SEQUENCE_RVA
    )
    if limit == nil
        or tech_candidate_sequence == nil
        or damage_sequence == nil
        or protected_damage_sequence == nil
        or outgoing_damage_sequence == nil then
        runtime.stopped = true
        log("STOPPED: LIMIT runtime data became unreadable.")
        return
    end

    limit = clamp_limit(limit)
    local tech_candidates = unsigned_sequence_delta(
        tech_candidate_sequence,
        runtime.last_tech_candidate_sequence
    )
    local damage_events = unsigned_sequence_delta(
        damage_sequence,
        runtime.last_damage_sequence
    )
    local protected_damage_events = unsigned_sequence_delta(
        protected_damage_sequence,
        runtime.last_protected_damage_sequence
    )
    local outgoing_damage_events = unsigned_sequence_delta(
        outgoing_damage_sequence,
        runtime.last_outgoing_damage_sequence
    )
    runtime.summary.damaging_hits =
        runtime.summary.damaging_hits + damage_events
    runtime.summary.protected_hits =
        runtime.summary.protected_hits + protected_damage_events
    runtime.summary.outgoing_hits =
        runtime.summary.outgoing_hits + outgoing_damage_events

    local risk_ok, risk_limit = apply_inverted_risk(damage_events)
    if not risk_ok then
        runtime.stopped = true
        log("STOPPED: inverted RISK update failed: "
            .. tostring(risk_limit))
        return
    end
    if risk_limit ~= nil then
        limit = risk_limit
    end

    queue_tech_candidates(tech_candidates)

    local parry_animation, parry_name = detect_parry_reaction(sora)
    if parry_animation ~= nil then
        local merged_candidate = consume_recent_tech_candidates(1)
        local source = "Sora " .. tostring(parry_name)
            .. " (animation " .. string.format(
                "0x%02X",
                parry_animation
            ) .. ")"
        if merged_candidate > 0 then
            source = source .. "; matching projectile candidate merged"
            runtime.parry_dedupe_credit = 0
        else
            runtime.parry_dedupe_frame = runtime.frame
            runtime.parry_dedupe_credit = 1
        end
        local award_ok, award_reason = award_limit(source)
        if not award_ok then
            runtime.stopped = true
            log("STOPPED: parry LIMIT award failed: "
                .. tostring(award_reason))
            return
        end
    end

    if parry_animation == nil
        and runtime.parry_dedupe_credit > 0
        and runtime.frame - runtime.parry_dedupe_frame
            <= CONFIG.TECH_CANDIDATE_DAMAGE_WINDOW_FRAMES then
        local late_duplicate = consume_recent_tech_candidates(1)
        if late_duplicate > 0 then
            runtime.parry_dedupe_credit = 0
            if debug_enabled(CONFIG.LOG_EACH_EVENT) then
                log("PROJECTILE CANDIDATE MERGED: late Tech-path candidate "
                    .. "matched the preceding parry reaction; no second "
                    .. "LIMIT award was added.")
            end
        end
    elseif runtime.frame - runtime.parry_dedupe_frame
        > CONFIG.TECH_CANDIDATE_DAMAGE_WINDOW_FRAMES then
        runtime.parry_dedupe_credit = 0
    end

    if damage_events > 0 then
        local rejected = consume_recent_tech_candidates(damage_events)
        runtime.summary.rejected_candidates =
            runtime.summary.rejected_candidates + rejected
        if debug_enabled(CONFIG.LOG_EACH_EVENT) and rejected > 0 then
            log("PROJECTILE CANDIDATE REJECTED: "
                .. tostring(rejected)
                .. " candidate(s) coincided with Sora taking damage; "
                .. "LIMIT was not awarded.")
        end
    end

    local candidates_ok, candidates_reason =
        flush_confirmed_projectile_candidates()
    if not candidates_ok then
        runtime.stopped = true
        log("STOPPED: projectile LIMIT confirmation failed: "
            .. tostring(candidates_reason))
        return
    end

    if debug_enabled(CONFIG.LOG_EACH_EVENT)
        and protected_damage_events > 0 then
        local original_delta = safe_read_signed_int(LAST_ORIGINAL_DELTA_RVA)
        local reduced_delta = safe_read_signed_int(LAST_REDUCED_DELTA_RVA)
        local original_damage = math.abs(original_delta or 0)
        local reduced_damage = math.abs(reduced_delta or 0)
        local loss_modifier = safe_read_signed_int(
            LIMIT_LOSS_MODIFIER_RVA
        ) or 0
        local effective_loss = effective_limit_amount(
            LIMIT_LOSS_PER_HIT_BASE,
            loss_modifier
        )
        local current_limit = clamp_limit(
            safe_read_int(LIMIT_VALUE_RVA) or limit
        )
        log("SORA HIT: finalized damage " .. tostring(original_damage)
            .. " -> " .. tostring(reduced_damage)
            .. " after 20% reduction; LIMIT="
            .. tostring(current_limit) .. "/" .. tostring(MAX_LIMIT)
            .. " after " .. string.format("%+d", -effective_loss)
            .. " (base " .. tostring(LIMIT_LOSS_PER_HIT_BASE)
            .. ", equipment modifier "
            .. string.format("%+d", loss_modifier) .. ")"
            .. (protected_damage_events > 1
                and " (" .. tostring(protected_damage_events)
                    .. " protected hits)"
                or "")
            .. ".")
    elseif debug_enabled(CONFIG.LOG_EACH_EVENT) and damage_events > 0 then
        local original_delta = safe_read_signed_int(LAST_ORIGINAL_DELTA_RVA)
        local original_damage = math.abs(original_delta or 0)
        local loss_modifier = safe_read_signed_int(
            LIMIT_LOSS_MODIFIER_RVA
        ) or 0
        local effective_loss = effective_limit_amount(
            LIMIT_LOSS_PER_HIT_BASE,
            loss_modifier
        )
        local current_limit = clamp_limit(
            safe_read_int(LIMIT_VALUE_RVA) or limit
        )
        log("SORA HIT: finalized damage " .. tostring(original_damage)
            .. "; no LIMIT damage reduction; LIMIT="
            .. tostring(current_limit) .. "/" .. tostring(MAX_LIMIT)
            .. " after " .. string.format("%+d", -effective_loss)
            .. " per hit.")
    end

    if debug_enabled(CONFIG.LOG_OUTGOING_DAMAGE)
        and outgoing_damage_events > 0 then
        local original_damage = safe_read_int(
            LAST_OUTGOING_ORIGINAL_RVA
        ) or 0
        local scaled_damage = safe_read_int(
            LAST_OUTGOING_SCALED_RVA
        ) or original_damage
        local hit_limit = clamp_limit(
            safe_read_int(LAST_OUTGOING_LIMIT_RVA) or limit
        )
        local tier = math.max(0, math.min(
            LIMIT_MAX_DAMAGE_TIERS,
            safe_read_int(LAST_OUTGOING_TIER_RVA) or 0
        ))
        local total_percent = 100
            + tier * LIMIT_DAMAGE_BONUS_PERCENT_PER_TIER
        log("SORA OUTPUT: pre-enemy damage " .. tostring(original_damage)
            .. " -> " .. tostring(scaled_damage)
            .. " at LIMIT=" .. tostring(hit_limit) .. "/"
            .. tostring(MAX_LIMIT) .. " (tier " .. tostring(tier)
            .. ", " .. tostring(total_percent)
            .. "% total) after DAMAGE_TAKEN and before "
            .. "DAMAGE_FLOOR/DAMAGE_CEILING"
            .. (outgoing_damage_events > 1
                and " (" .. tostring(outgoing_damage_events)
                    .. " scaled hits this frame; last shown)"
                or "")
            .. ".")
    end

    limit = clamp_limit(safe_read_int(LIMIT_VALUE_RVA) or limit)
    if limit ~= runtime.last_limit then
        runtime.persistence_dirty = true
        runtime.pending_persisted_limit = limit
    end
    local saved, save_reason = flush_pending_persistence(false)
    if not saved then
        log("PERSISTENCE WARNING: " .. tostring(save_reason))
        runtime.persistence_available = false
    end
    maybe_log_periodic_summary(limit)

    runtime.last_limit = limit
    runtime.last_tech_candidate_sequence = tech_candidate_sequence
    runtime.last_damage_sequence = damage_sequence
    runtime.last_protected_damage_sequence = protected_damage_sequence
    runtime.last_outgoing_damage_sequence = outgoing_damage_sequence
end

function _OnInit()
    local enabled_rows = GEAR_CONTROLLER.compile()
    runtime.initialized = false
    runtime.stopped = false
    runtime.waiting_logged = false
    log("Initialization complete; " .. tostring(enabled_rows)
        .. " enabled Keyblade/accessory row(s). Waiting for the exact "
        .. "Steam Global build and loaded Sora data.")
end

function _OnFrame()
    if runtime.stopped then
        return
    end

    if not runtime.initialized then
        if not build_is_exact() or not character_is_ready() then
            if not runtime.waiting_logged then
                runtime.waiting_logged = true
                log("WAITING: build sentinel or Sora data is not ready.")
            end
            return
        end

        local ok, reason = initialize_runtime()
        if not ok then
            runtime.stopped = true
            log("INSTALL REFUSED: " .. tostring(reason)
                .. ". No unknown code was overwritten.")
        end
        return
    end

    update_runtime()
end
