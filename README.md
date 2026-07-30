# SkillWatch v0.3.0 (Ashita v4.30 rewrite)

Overlay that shows the ability/spell a mob is readying, with an optional blinking
alert for skills you care about (stun targets, etc).

## What changed vs 0.2.1

**Detection is now packet-driven.** The addon parses incoming action packets
(`0x28`, category 7 = "readies", category 8 = "starts casting") instead of
scraping the chat box for the word "readies".

Consequences:

* **Fully compatible with SimpleLog.** No need to edit
  `simplelog/lib/constants.lua`, no need to move mode `43` out of `block_modes`.
  SimpleLog blocks/rewrites *chat text*; SkillWatch no longer reads chat text.
* Works when SimpleLog rewrites the readies line into its own condensed format
  (which stripped the word "readies" entirely and broke the old parser).
* Language- and format-independent. Ability names come from Ashita's resource
  manager (`monsters.abilities`), so they always match exactly.
* Detection is no longer dependent on the mob's name appearing in the message,
  which broke on `-`-hyphenated names, common nouns ("The Mandragora"), and
  pattern metacharacters.

### Bugs fixed

* `EndTabBar()` was called even when `BeginTabBar()` returned false → ImGui assert.
* Debug tab item was created outside the tab bar scope.
* `imgui.Begin('SkillWatchOL', true, ...)` passed a boolean where a table/nil is
  expected; that whole invisible window is gone.
* `filter_settings` register callback saved `general_settings`, so filter changes
  could be lost.
* `default_filterSettings = T{abilityFilters,}` referenced an undefined global.
* `overlay.search[1]` / `customFilter[1]` were `nil` on first frame → runtime error.
* Search used the input as a Lua pattern; typing `(`, `?`, `%` etc. errored.
  Now plain substring matching.
* Blink color used `bit.tobit()` on floats and produced signed values; replaced
  with plain arithmetic ARGB and a clean triangle wave (no `blinkDir` flip-flop).
* Default blink RGB was `0,0,0` (invisible blink). Now `255,0,0`.
* Empty/whitespace ImGui labels (`''`, `' '`, `'\13'`) caused ID collisions.
  All widgets now use explicit `##ids`.
* Entire 1159-entry ability table was serialized into the settings file on every
  save. Only enabled names are stored now.
* Overlay position was saved every frame it changed; now throttled to 1s.

### New

* `Show mob name` — prefixes the overlay with the caster.
* `Current target only` — on by default (old behaviour); turn off to see readies
  from any nearby mob.
* `Mobs only` — ignore players/trusts/pets.
* `Also watch spellcasting` — catches "starts casting" (category 8) too.
* `Display Duration (sec)` — replaces the hardcoded 3.0s window.
* `Legacy chat fallback` — off by default. If enabled, the old text parser runs
  *only* until the first successful packet detection, then permanently defers.
* Timer clears early when the mob actually fires the move (categories 3/4/11).

## Install

Drop the `skillwatch` folder into `<Ashita>/addons/`.

```
/addon load skillwatch
```

## Commands

| Command | Effect |
|---|---|
| `/skillwatch` or `/sw` | toggle config window |
| `/sw debug` | toggle the Debug tab |
| `/sw reload` | rebuild the ability name list from resources |
| `/sw reset` | reset overlay position to 100,100 |

## Notes

* `data/abilities.txt` is retained only as a fallback if the resource manager
  returns nothing at load time. Normally the list is built from Ashita resources.
* The overlay is an Ashita font object — drag it to reposition while the config
  window is open ("Adjust Mode").

-----------------------------------------------------------------------------------------------------------------------------------------

### What is it?
Skillwatch is an add-on for FFXI's third-party loader and hook Ashita (https://www.ashitaxi.com/).
Very simply, the purpose of this add-on is to have a clearer way to identify the moment when enemy mobs "ready" a skill.
This could be useful in a variety of situations, for example, when people are playing with relevant ping issues or the time window to react to such event is in general too short.
<br></br>
### What is not?
This add-on is <b>NOT</b> a bot. It simply provides enhanced feedback on enemy mobs readying their skills with the same timing the typical "X readies Y" message would appear in the chat box.
<br></br>
### How does it work?
In short, it's a combination of parsing the chat box looking for a message, matching it with Entity informations provided by Ashita hook and drawing some visual feedback overlay.
<br></br>
### Main features
By default, the add-on displays on an overlay (text +  background box + time bar) ALL the incoming skills from enemy mobs with the exception of those without charging time (e.g. Jump).\
The overlay can be configured in different ways (see details below), for example, by filtering certain skills to add a blinking alert effect to the overlay when they are incoming.\
It is also possible to just display the filtered skills (very useful to target specific skill to which you'd like to react with a stun!).\
The overlay has different visual options such as size adjustment, repositioning, blinking color, etc.
![Overlay1](https://github.com/ariel-logos/ElfyLab/blob/master/img/overlay1fixed.gif)  | ![Overlay2](https://github.com/ariel-logos/ElfyLab/blob/master/img/overlay2.gif)
:------------------|------------------
Normal skill overlay | Filtered skill overlay (blinking alert effect)

### Installation
Go over the <a href="[https://github.com/ariel-logos/SkillWatch/releases](https://github.com/abhinatha/SkillWatch-Updated/releases)" target="_blank">Releases</a> page, download the latest version and unpack it in the add-on folder in your Ashita installation folder. You should now have among the other add-on folders the "skillwatch" one!
<br></br>
### Compatibility Issues
None now

### Functionalities

#### Commands
```/addon load skillwatch``` Loads the add-on in Ashita.

```/addon unload skillwatch``` Unloads the add-on from Ashita.

```/skillwatch``` Shows/hides the config UI.
<br></br>
#### Filters tab
This tab allows you to select which skill you want to have the "blinking" alert effect to better highlight those relevant for you.\
You can obviously select multiple skills on which to apply the blinking effect.\
Everything set here is saved in the preferences.
<ol>
  <li><b>Search:</b> textbox that you can use to quickly look up mobs' skills in the Skills list (Fig.2).</li>
  <li><b>Skills:</b> list of mobs' skills, select the one you want to filter to add the blinking effect.</li>
  <li><b>Enable:</b> after selecting a skill you can use this toggle checkbox to enable or disable the blinking effect for that skill.</li>
  <li><b>Show Enabled only:</b> toggle checkbox to quickly show in the Skills list only the skill for which the blinking effect is enabled.</li>
  <li><b>Disable All:</b> button to quickly remove the check mark from the Enabled checkbox from ALL the skills effectively resetting the list.</li>
  <li><b>Custom Filter:</b> textbox to quickly add custom text to match against the name of the skills used by mobs (Fig.3) (e.g. Writing "Toss" and enabling the checkbox will add the blinking effect on all the skills containing the word Toss). This text is case sensitive!!!</li>
</ol>

![1](https://github.com/ariel-logos/SkillWatch/assets/78350872/3d8a14e9-b8dd-4227-99ba-6369b511ba29)|![2](https://github.com/ariel-logos/SkillWatch/assets/78350872/19ce8c78-9851-4424-8e82-8aea4f1c43cd)|![3](https://github.com/ariel-logos/SkillWatch/assets/78350872/31aee711-072d-400a-a867-e8180ccfdd5a)
:-------------------------|-------------------------|-------------------------
Fig. 1          |  Fig. 2           | Fig. 3 
#### Settings tab
In this tab you can adjust several add-on settings, in particular:
<ol>
  <li><b>Size:</b> sets the size of the overlay.</li>
  <li><b>BG Transparency:</b> sets the transparency of the background box.</li>
  <li><b>Blinking RGB:</b> using the 3 sliders R,G,B below, sets the color of the blinking effect.</li>
  <li><b>Blinking Speed:</b> sets the rate at which the text background to notify incoming skills set in the Filters tab.</li>
  <li><b>Only trigger on filtered skills:</b> the overlay will only appear when one of the selected skills in the Filters tab is being used by the enemy mob.</li>
  <li><b>Right justified:</b> the text and background box will resize expanding towards the left (default: right).</li>
  <li><b>Ignore non-custom filter:</b> the overlay will only appear when the text in the Custom Filter textbox set Filters tab is recognized. Ignores other selected filter from the Skills list.</li>
  <li><b>Hide timer bar:</b> hides the bar appearing at the bottom of the text showing the time since the skill detection.</li>
</ol>


<p align="center">
<a href="https://github.com/ariel-logos/SkillWatch/assets/78350872/726d83c8-ba8d-4cbe-89cb-9050527a8255"><img src="https://github.com/ariel-logos/SkillWatch/assets/78350872/726d83c8-ba8d-4cbe-89cb-9050527a8255.png" alt="SkillWatch Overlay"/></a>
</p>
