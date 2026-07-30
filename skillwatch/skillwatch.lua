--[[
* SkillWatch - mob TP move / spell "readies" overlay for Ashita v4
*
* Original addon by Arielfy.
* v0.3.0 rewrite: packet-driven detection (0x28 action packet) instead of
* chat-text scraping, which makes it fully compatible with SimpleLog and any
* other addon that blocks or rewrites incoming chat lines.
--]]

addon.name      = 'skillwatch';
addon.author    = 'Arielfy (v0.3.0 rewrite)';
addon.version   = '0.3.0';
addon.desc      = 'Displays abilities/spells being readied by mobs.';
addon.link      = 'https://github.com/ariel-logos/SkillWatch';

require('common');
local imgui    = require('imgui');
local fonts    = require('fonts');
local prims    = require('primitives');
local settings = require('settings');

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local ACT_CAT_WS_START      = 7;    -- mob TP move / weaponskill "readies"
local ACT_CAT_SPELL_START   = 8;    -- "starts casting"
local ACT_CAT_ITEM_START    = 9;
local ACT_CAT_SPELL_FINISH  = 4;
local ACT_CAT_WS_FINISH     = 3;
local ACT_CAT_MOB_TP_FINISH = 11;

local MOB_ABILITY_BASE      = 0x100;    -- monsters.abilities string index == id - 0x100
local SPAWNFLAG_MOB         = 0x10;
local DEDUPE_WINDOW         = 0.25;     -- seconds

----------------------------------------------------------------------------------------------------
-- Defaults
----------------------------------------------------------------------------------------------------

local default_settings = T{
    font = T{
        visible         = false,
        font_family     = 'Franklin Gothic',
        bold            = true,
        font_height     = 12,
        draw_flags      = 0x10,
        color           = 0xFFFFFFFF,
        color_outline   = 0xFF000000,
        position_x      = 100,
        position_y      = 100,
        padding         = 3,
        right_justified = false,
        background      = T{
            visible = true,
            color   = 0x88000000,
            scale_x = 1.0,
            scale_y = 1.0,
            width   = 0.0,
            height  = 0.0,
        },
    },

    size                = T{ 1.0 },
    transparency        = T{ 0.5 },
    maxTime             = T{ 3.0 },

    blinkR              = T{ 255.0 },
    blinkG              = T{ 0.0 },
    blinkB              = T{ 0.0 },
    blinkingSpeed       = T{ 1.0 },

    showOnlyEnabled     = T{ false },   -- filter list: show only enabled entries
    showOnlyBlink       = T{ false },   -- only draw overlay for filtered skills
    justifyRight        = T{ false },
    hideSkillBar        = T{ false },
    showMobName         = T{ false },

    customFilter        = T{ '' },
    customFilterEnabled = T{ false },
    skipNotCustom       = T{ false },

    targetOnly          = T{ true },    -- only react to your current target / subtarget
    mobsOnly            = T{ true },    -- ignore players / trusts / pets
    watchSpells         = T{ false },   -- also catch "starts casting"
    useTextFallback     = T{ false },   -- legacy chat parsing (auto-disables once packets work)
};

local default_filters = T{
    enabled = T{},                      -- [ability name] = true
};

local skillbar_defaults = T{
    visible    = false,
    color      = 0xFFFFFFFF,
    can_focus  = false,
    locked     = true,
    width      = 200,
    height     = 4,
    position_x = 0,
    position_y = 0,
};

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local sw = T{
    settings        = nil,
    filters         = nil,

    font            = nil,
    skillBar        = nil,

    abilities       = T{},              -- sorted list of every known name
    filtered        = T{},              -- indices into abilities, rebuilt when search changes
    selected        = T{ -1 },
    search          = T{ '' },
    lastSearch      = nil,
    lastShowEnabled = nil,

    isSettingsOpen  = T{ false },
    debugMode       = false,

    -- active detection
    active          = false,
    abilityName     = '',
    abilityId       = 0,
    mobName         = '',
    mobIndex        = 0,
    startTime       = 0,
    timer           = 0,
    isBlinking      = false,

    packetSeen      = false,            -- a 0x28 detection has happened this session
    lastKey         = '',
    lastKeyTime     = 0,

    lastSavedX      = nil,
    lastSavedY      = nil,
    saveQueued      = 0,
};

----------------------------------------------------------------------------------------------------
-- Settings plumbing
----------------------------------------------------------------------------------------------------

local function save_settings()
    settings.save('general_settings');
end

local function save_filters()
    settings.save('filter_settings');
end

settings.register('general_settings', 'general_settings_update', function (s)
    if (s ~= nil) then sw.settings = s; end
    settings.save('general_settings');
end);

settings.register('filter_settings', 'filter_settings_update', function (s)
    if (s ~= nil) then sw.filters = s; end
    settings.save('filter_settings');
end);

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

-- Build an unsigned ARGB value without relying on signed bit ops.
local function argb(a, r, g, b)
    a = math.floor(math.max(0, math.min(255, a)));
    r = math.floor(math.max(0, math.min(255, r)));
    g = math.floor(math.max(0, math.min(255, g)));
    b = math.floor(math.max(0, math.min(255, b)));
    return (a * 16777216) + (r * 65536) + (g * 256) + b;
end

local function resource_manager()
    return AshitaCore:GetResourceManager();
end

-- Resolve a category-7/11 ability id to its English name.
local function ability_name(id)
    local rm = resource_manager();
    if (rm == nil) then return nil; end

    if (id >= MOB_ABILITY_BASE) then
        local n = rm:GetString('monsters.abilities', id - MOB_ABILITY_BASE, 2);
        if (n ~= nil and n ~= '') then return n; end
    end

    local a = rm:GetAbilityById(id);
    if (a ~= nil and a.Name ~= nil and a.Name[1] ~= nil and a.Name[1] ~= '') then
        return a.Name[1];
    end

    return nil;
end

local function spell_name(id)
    local rm = resource_manager();
    if (rm == nil) then return nil; end
    local s = rm:GetSpellById(id);
    if (s ~= nil and s.Name ~= nil and s.Name[1] ~= nil and s.Name[1] ~= '') then
        return s.Name[1];
    end
    return nil;
end

local function entity_by_serverid(sid)
    -- Fast path: mob server ids normally encode their entity index in the low bits.
    local idx = bit.band(sid, 0x7FF);
    local ent = GetEntity(idx);
    if (ent ~= nil and ent.ServerId == sid) then
        return ent, idx;
    end
    for x = 0, 2303 do
        ent = GetEntity(x);
        if (ent ~= nil and ent.ServerId == sid) then
            return ent, x;
        end
    end
    return nil, nil;
end

local function is_watched_index(index)
    if (not sw.settings.targetOnly[1]) then return true; end
    local tm = AshitaCore:GetMemoryManager():GetTarget();
    if (tm == nil) then return false; end
    return (index == tm:GetTargetIndex(0)) or (index == tm:GetTargetIndex(1));
end

----------------------------------------------------------------------------------------------------
-- Ability name list (filter UI source)
----------------------------------------------------------------------------------------------------

local function load_abilities_from_file()
    local list = T{};
    local f = io.open(addon.path .. 'data/abilities.txt', 'r');
    if (f == nil) then
        f = io.open(addon.path .. '\\data\\abilities.txt', 'r');
    end
    if (f == nil) then return list; end
    for line in f:lines() do
        line = line:gsub('[\r\n]', '');
        if (line ~= '') then list:append(line); end
    end
    f:close();
    return list;
end

local function build_ability_list()
    local seen = {};
    local list = T{};
    local rm   = resource_manager();

    if (rm ~= nil) then
        -- Monster TP moves.
        local misses = 0;
        for i = 1, 4116 do
            local n = rm:GetString('monsters.abilities', i, 2);
            if (n == nil or n == '') then
                misses = misses + 1;
                if (misses > 64) then break; end
            else
                misses = 0;
                if (not seen[n]) then seen[n] = true; list:append(n); end
            end
        end
        -- Weaponskills (pets / charmed players also "ready" these).
        for i = 1, 255 do
            local a = rm:GetAbilityById(i);
            if (a ~= nil and a.Name ~= nil and a.Name[1] ~= nil and a.Name[1] ~= '') then
                local n = a.Name[1];
                if (not seen[n]) then seen[n] = true; list:append(n); end
            end
        end
    end

    if (#list == 0) then
        list = load_abilities_from_file();
    end

    table.sort(list, function (a, b) return a:lower() < b:lower(); end);
    return list;
end

local function rebuild_filtered_list()
    local q       = (sw.search[1] or ''):lower();
    local onlyEn  = sw.settings.showOnlyEnabled[1];
    local out     = T{};
    for i = 1, #sw.abilities do
        local name = sw.abilities[i];
        local ok   = true;
        if (onlyEn and not sw.filters.enabled[name]) then ok = false; end
        if (ok and q ~= '' and string.find(name:lower(), q, 1, true) == nil) then ok = false; end
        if (ok) then out:append(i); end
    end
    sw.filtered        = out;
    sw.lastSearch      = q;
    sw.lastShowEnabled = onlyEn;
end

----------------------------------------------------------------------------------------------------
-- Filter evaluation
----------------------------------------------------------------------------------------------------

local function is_filtered(name)
    if (name == nil or name == '') then return false; end

    local hit = false;

    if (not sw.settings.skipNotCustom[1]) then
        if (sw.filters.enabled[name]) then hit = true; end
    end

    if (not hit and sw.settings.customFilterEnabled[1]) then
        local cf = sw.settings.customFilter[1] or '';
        if (cf ~= '' and string.find(name, cf, 1, true) ~= nil) then hit = true; end
    end

    return hit;
end

----------------------------------------------------------------------------------------------------
-- Timer
----------------------------------------------------------------------------------------------------

local function reset_timer()
    sw.active     = false;
    sw.timer      = 0;
    sw.startTime  = 0;
    sw.isBlinking = false;
end

local function start_timer(name, id, mob, mobIndex)
    sw.abilityName = name;
    sw.abilityId   = id;
    sw.mobName     = mob or '';
    sw.mobIndex    = mobIndex or 0;
    sw.active      = true;
    sw.startTime   = os.clock();
    sw.timer       = 0;
    sw.isBlinking  = is_filtered(name);
end

local function update_timer()
    if (not sw.active) then return; end
    sw.timer = os.clock() - sw.startTime;
    if (sw.timer > sw.settings.maxTime[1]) then
        reset_timer();
    end
end

----------------------------------------------------------------------------------------------------
-- Detection
----------------------------------------------------------------------------------------------------

local function accept(key)
    local now = os.clock();
    if (key == sw.lastKey and (now - sw.lastKeyTime) < DEDUPE_WINDOW) then
        return false;
    end
    sw.lastKey     = key;
    sw.lastKeyTime = now;
    return true;
end

local function handle_action(data)
    local t = data:totable();
    if (#t < 40) then return; end

    local category = ashita.bits.unpack_be(t, 82, 4);

    local isStart  = (category == ACT_CAT_WS_START)
                  or (sw.settings.watchSpells[1] and category == ACT_CAT_SPELL_START);
    local isFinish = (category == ACT_CAT_MOB_TP_FINISH)
                  or (category == ACT_CAT_WS_FINISH)
                  or (category == ACT_CAT_SPELL_FINISH);

    if (not isStart and not isFinish) then return; end

    local actorId = ashita.bits.unpack_be(t, 40, 32);
    if (actorId == 0) then return; end

    local ent, index = entity_by_serverid(actorId);
    if (ent == nil) then return; end

    if (isStart) then
        if (sw.settings.mobsOnly[1] and bit.band(ent.SpawnFlags, SPAWNFLAG_MOB) == 0) then return; end
        if (not is_watched_index(index)) then return; end

        -- Start packets carry the ability/spell id in the first target's first action param.
        local abilId = ashita.bits.unpack_be(t, 213, 17);
        local name;
        if (category == ACT_CAT_SPELL_START) then
            name = spell_name(abilId);
        else
            name = ability_name(abilId);
        end
        if (name == nil or name == '') then return; end

        if (not accept(('s%d:%d:%d'):fmt(index, category, abilId))) then return; end

        sw.packetSeen = true;
        start_timer(name, abilId, ent.Name, index);
        return;
    end

    -- Finish packets clear an active detection from the same actor.
    if (sw.active and index == sw.mobIndex) then
        reset_timer();
    end
end

ashita.events.register('packet_in', 'skillwatch_packet_in', function (e)
    if (e.id ~= 0x28) then return; end
    if (e.blocked) then return; end
    if (sw.settings == nil) then return; end

    local ok, err = pcall(handle_action, e.data);
    if (not ok and sw.debugMode) then
        print(('[skillwatch] packet error: %s'):fmt(tostring(err)));
    end
end);

----------------------------------------------------------------------------------------------------
-- Legacy chat fallback (off by default; disables itself once packets are proven to work)
----------------------------------------------------------------------------------------------------

ashita.events.register('text_in', 'skillwatch_text_in', function (e)
    if (sw.settings == nil) then return; end
    if (not sw.settings.useTextFallback[1]) then return; end
    if (sw.packetSeen) then return; end

    local msg = e.message;
    if (msg == nil) then return; end

    local s, en = string.find(msg, ' readies ', 1, true);
    if (s == nil) then
        s, en = string.find(msg, ' ready ', 1, true);
    end
    if (s == nil) then return; end

    local mob  = msg:sub(1, s - 1):gsub('^%s+', ''):gsub('%c', '');
    local name = msg:sub(en + 1):gsub('%c', ''):gsub('%.%s*$', ''):gsub('%s+$', '');
    if (name == '') then return; end

    if (not accept('t' .. name)) then return; end
    start_timer(name, 0, mob, -1);
end);

----------------------------------------------------------------------------------------------------
-- Overlay rendering
----------------------------------------------------------------------------------------------------

local function background_color()
    local alpha = (1.0 - sw.settings.transparency[1]) * 255.0;

    if (not sw.isBlinking and not sw.isSettingsOpen[1]) then
        return argb(alpha, 0, 0, 0);
    end

    local speed = sw.settings.blinkingSpeed[1];
    if (speed <= 0) then
        return argb(alpha, sw.settings.blinkR[1], sw.settings.blinkG[1], sw.settings.blinkB[1]);
    end

    -- Triangle wave 0 -> 1 -> 0.
    local phase = (os.clock() * speed) % 1.0;
    local wave  = 1.0 - math.abs((phase * 2.0) - 1.0);

    return argb(alpha,
        sw.settings.blinkR[1] * wave,
        sw.settings.blinkG[1] * wave,
        sw.settings.blinkB[1] * wave);
end

local function update_skillbar(visible)
    if (sw.skillBar == nil or sw.font == nil) then return; end

    if (not visible or sw.settings.hideSkillBar[1]) then
        sw.skillBar.visible = false;
        return;
    end
    sw.skillBar.visible = true;

    local size = SIZE.new();
    sw.font:GetTextSize(size);

    local maxTime  = math.max(0.1, sw.settings.maxTime[1]);
    local pct      = math.max(0.0, math.min(1.0, sw.timer / maxTime));
    local widthMax = size.cx + (sw.font.padding * 2);

    sw.skillBar.height = math.max(2, math.floor(size.cy / 8));

    if (not sw.settings.justifyRight[1]) then
        sw.skillBar.width      = widthMax * pct;
        sw.skillBar.position_x = sw.font.position_x - sw.font.padding;
    else
        sw.skillBar.width      = -(widthMax * pct);
        sw.skillBar.position_x = sw.font.position_x + sw.font.padding;
    end

    sw.skillBar.position_y = sw.font.position_y + sw.font.padding + size.cy;
end

local function render_overlay()
    if (sw.font == nil) then return; end

    sw.font.right_justified   = sw.settings.justifyRight[1];
    sw.font.background.color  = background_color();

    -- Adjust mode: settings window open, so the user can position the overlay.
    if (sw.isSettingsOpen[1] and not sw.active) then
        sw.font:SetText(' Adjust Mode ');
        sw.font:SetVisible(true);
        sw.timer = sw.settings.maxTime[1] * 0.5;
        update_skillbar(true);
        return;
    end

    if (not sw.active) then
        sw.font:SetText('');
        sw.font:SetVisible(false);
        update_skillbar(false);
        return;
    end

    if (sw.settings.showOnlyBlink[1] and not sw.isBlinking) then
        sw.font:SetVisible(false);
        update_skillbar(false);
        return;
    end

    local text = sw.abilityName;
    if (sw.settings.showMobName[1] and sw.mobName ~= '') then
        text = ('%s: %s'):fmt(sw.mobName, sw.abilityName);
    end

    sw.font:SetText(' ' .. text .. ' ');
    sw.font:SetVisible(true);
    update_skillbar(true);
end

----------------------------------------------------------------------------------------------------
-- Config UI
----------------------------------------------------------------------------------------------------

local function render_filters_tab()
    if (imgui.InputText('Search##sw_search', sw.search, 255)) then
        rebuild_filtered_list();
    end

    if (sw.lastSearch ~= (sw.search[1] or ''):lower() or sw.lastShowEnabled ~= sw.settings.showOnlyEnabled[1]) then
        rebuild_filtered_list();
    end

    imgui.BeginGroup();
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Skills');
    imgui.BeginChild('##sw_leftpane', { 250, 250, }, true);
    for n = 1, #sw.filtered do
        local idx  = sw.filtered[n];
        local name = sw.abilities[idx];
        local mark = sw.filters.enabled[name] and '* ' or '';
        if (imgui.Selectable(('%s%s##sw_ab%d'):fmt(mark, name, idx), sw.selected[1] == idx)) then
            sw.selected[1] = idx;
        end
    end
    imgui.EndChild();
    imgui.EndGroup();

    imgui.SameLine();

    imgui.BeginGroup();
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Enable');
    imgui.BeginChild('##sw_rightpane', { 75, 250, }, true);
    if (sw.selected[1] > 0 and sw.abilities[sw.selected[1]] ~= nil) then
        local name = sw.abilities[sw.selected[1]];
        local box  = { sw.filters.enabled[name] == true };
        if (imgui.Checkbox('##sw_enable', box)) then
            if (box[1]) then
                sw.filters.enabled[name] = true;
            else
                sw.filters.enabled[name] = nil;
            end
            save_filters();
            rebuild_filtered_list();
        end
    end
    imgui.EndChild();
    imgui.EndGroup();

    if (imgui.Checkbox('Show Enabled only##sw_onlyen', sw.settings.showOnlyEnabled)) then
        save_settings();
        rebuild_filtered_list();
    end

    if (imgui.Button('Disable All##sw_disall')) then
        sw.filters.enabled = T{};
        save_filters();
        rebuild_filtered_list();
    end

    imgui.Separator();
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Custom Filter (case sensitive)');
    if (imgui.InputText('##sw_custom', sw.settings.customFilter, 128)) then
        save_settings();
    end
    imgui.SameLine();
    if (imgui.Checkbox('Enabled##sw_customen', sw.settings.customFilterEnabled)) then
        save_settings();
    end
end

local function render_settings_tab()
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Size');
    if (imgui.SliderFloat('##sw_size', sw.settings.size, 0.1, 3.0, '%0.1f')) then
        local h = math.floor(11 * sw.settings.size[1]) + 1;
        sw.settings.font.font_height = h;
        if (sw.font ~= nil) then
            sw.font.font_height = h;
            sw.font.padding     = h / 4;
        end
        save_settings();
    end

    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'BG Transparency');
    if (imgui.SliderFloat('##sw_trans', sw.settings.transparency, 0.0, 1.0, '%0.2f')) then
        save_settings();
    end

    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Blinking RGB');
    if (imgui.SliderFloat('R##sw_r', sw.settings.blinkR, 0.0, 255.0, '%1.0f')) then save_settings(); end
    if (imgui.SliderFloat('G##sw_g', sw.settings.blinkG, 0.0, 255.0, '%1.0f')) then save_settings(); end
    if (imgui.SliderFloat('B##sw_b', sw.settings.blinkB, 0.0, 255.0, '%1.0f')) then save_settings(); end

    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Blinking Speed');
    if (imgui.SliderFloat('##sw_speed', sw.settings.blinkingSpeed, 0.0, 10.0, '%0.1f')) then save_settings(); end

    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Display Duration (sec)');
    if (imgui.SliderFloat('##sw_maxtime', sw.settings.maxTime, 0.5, 10.0, '%0.1f')) then save_settings(); end

    imgui.Separator();
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Options');

    if (imgui.Checkbox('Only trigger on filtered skills##sw_onlyblink', sw.settings.showOnlyBlink)) then save_settings(); end
    if (imgui.Checkbox('Right justified##sw_right', sw.settings.justifyRight)) then save_settings(); end
    if (imgui.Checkbox('Ignore non-custom filters##sw_skipnc', sw.settings.skipNotCustom)) then save_settings(); end
    if (imgui.Checkbox('Hide timer bar##sw_hidebar', sw.settings.hideSkillBar)) then save_settings(); end
    if (imgui.Checkbox('Show mob name##sw_mobname', sw.settings.showMobName)) then save_settings(); end
    if (imgui.Checkbox('Current target only##sw_targonly', sw.settings.targetOnly)) then save_settings(); end
    if (imgui.Checkbox('Mobs only##sw_mobsonly', sw.settings.mobsOnly)) then save_settings(); end
    if (imgui.Checkbox('Also watch spellcasting##sw_spells', sw.settings.watchSpells)) then save_settings(); end
    if (imgui.Checkbox('Legacy chat fallback##sw_textfb', sw.settings.useTextFallback)) then save_settings(); end
end

local function render_debug_tab()
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('packet detection seen: %s'):fmt(tostring(sw.packetSeen)));
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('abilities loaded: %d'):fmt(#sw.abilities));
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('active: %s'):fmt(tostring(sw.active)));
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('mob: %s (index %d)'):fmt(sw.mobName, sw.mobIndex));
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('ability: %s (id %d)'):fmt(sw.abilityName, sw.abilityId));
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('blinking: %s'):fmt(tostring(sw.isBlinking)));
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('timer: %0.2f / %0.2f'):fmt(sw.timer, sw.settings.maxTime[1]));
    if (sw.font ~= nil) then
        imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, ('font: %s h=%d pos=%d,%d'):fmt(
            tostring(sw.font.font_family), sw.font.font_height, sw.font.position_x, sw.font.position_y));
    end
    imgui.Separator();
    imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, 'Enabled filters:');
    for k, _ in pairs(sw.filters.enabled) do
        imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, k);
    end
end

local function render_config()
    if (not sw.isSettingsOpen[1]) then return; end

    imgui.SetNextWindowSize({ 380, 500, }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 380, 500, }, { 1600, 1600, });

    if (imgui.Begin('SkillWatch##sw_config', sw.isSettingsOpen, ImGuiWindowFlags_NoResize)) then
        if (imgui.BeginTabBar('##sw_tabbar', ImGuiTabBarFlags_NoCloseWithMiddleMouseButton)) then
            if (imgui.BeginTabItem('Filters', nil)) then
                render_filters_tab();
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Settings', nil)) then
                render_settings_tab();
                imgui.EndTabItem();
            end
            if (sw.debugMode and imgui.BeginTabItem('Debug', nil)) then
                render_debug_tab();
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end
    end
    imgui.End();
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------

ashita.events.register('d3d_present', 'skillwatch_present', function ()
    if (sw.settings == nil or sw.font == nil) then return; end

    -- Persist overlay position when the user drags it (throttled).
    if (sw.font.position_x ~= sw.settings.font.position_x or sw.font.position_y ~= sw.settings.font.position_y) then
        sw.settings.font.position_x = sw.font.position_x;
        sw.settings.font.position_y = sw.font.position_y;
        sw.saveQueued = os.clock();
    end
    if (sw.saveQueued > 0 and (os.clock() - sw.saveQueued) > 1.0) then
        sw.saveQueued = 0;
        save_settings();
    end

    update_timer();
    render_config();
    render_overlay();
end);

ashita.events.register('load', 'skillwatch_load', function ()
    sw.settings = settings.load(default_settings, 'general_settings');
    sw.filters  = settings.load(default_filters, 'filter_settings');

    if (sw.filters.enabled == nil) then sw.filters.enabled = T{}; end

    local h = math.floor(11 * sw.settings.size[1]) + 1;
    sw.settings.font.font_height = h;

    sw.font          = fonts.new(sw.settings.font);
    sw.font.font_height = h;
    sw.font.padding  = h / 4;
    sw.font.background.border_visible = true;
    sw.font.background.border_color   = 0xFFFFFFFF;
    sw.font:SetVisible(false);

    sw.skillBar = prims.new(skillbar_defaults);

    sw.abilities = build_ability_list();
    rebuild_filtered_list();

    reset_timer();
end);

ashita.events.register('unload', 'skillwatch_unload', function ()
    if (sw.settings ~= nil) then save_settings(); end
    if (sw.filters ~= nil) then save_filters(); end

    if (sw.font ~= nil) then
        sw.font:destroy();
        sw.font = nil;
    end
    if (sw.skillBar ~= nil) then
        sw.skillBar:destroy();
        sw.skillBar = nil;
    end
end);

ashita.events.register('command', 'skillwatch_command', function (e)
    local args = e.command:args();
    if (#args == 0) then return; end
    if (not args[1]:any('/skillwatch', '/sw')) then return; end

    e.blocked = true;

    local sub = (args[2] or ''):lower();

    if (sub == '' or sub == 'config' or sub == 'menu') then
        sw.isSettingsOpen[1] = not sw.isSettingsOpen[1];
        return;
    end

    if (sub == 'debug') then
        sw.debugMode = not sw.debugMode;
        print(('[skillwatch] debug mode: %s'):fmt(tostring(sw.debugMode)));
        return;
    end

    if (sub == 'reload') then
        sw.abilities = build_ability_list();
        rebuild_filtered_list();
        print(('[skillwatch] reloaded %d ability names.'):fmt(#sw.abilities));
        return;
    end

    if (sub == 'reset') then
        sw.settings.font.position_x = 100;
        sw.settings.font.position_y = 100;
        if (sw.font ~= nil) then
            sw.font.position_x = 100;
            sw.font.position_y = 100;
        end
        save_settings();
        print('[skillwatch] overlay position reset.');
        return;
    end

    print('[skillwatch] /skillwatch | /sw  -- toggle config');
    print('[skillwatch] /sw debug   -- toggle debug tab');
    print('[skillwatch] /sw reload  -- rebuild ability name list');
    print('[skillwatch] /sw reset   -- reset overlay position');
end);
