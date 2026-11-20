# Dungeon Tracker – how it works

For contributors, and for authors who want to see a real plugin built on the [OneForAll plugin API](https://github.com/Emzime/OneForAll-API). For a step-by-step guide to writing a plugin, see the API's [plugin guide](https://github.com/Emzime/OneForAll-API/blob/main/docs/plugin-guide.md).

## Files

| File | Content |
|---|---|
| `OneForAll_DungeonTracker.toc` | `## Dependencies: OneForAll` and the two saved variables. |
| `Locales.lua` | The plugin's texts in Deutsch, Français, Español, Português (Brasil). English is the default. |
| `DungeonTracker.lua` | Everything else: data access, window, kill detection, XP and gold, runs, options, commands, log. |

## What it uses from the API

The plugin reaches OneForAll only through `OneForAllAPI` (version 2 or later), and never writes into it.

| Need | API |
|---|---|
| Register, check the version | `API.VERSION`, `RegisterPlugin` |
| Dungeons and their bosses (English names, NPC IDs, aliases, rare flags) | `GetDungeon`, `GetDungeonsByInstanceID`, `FindCurrentDungeon`, `IsSummonedBoss`, `API.ipairs` |
| Names in the player's language | `DungeonName`, `Name` |
| Opening a boss in OneForAll on click | `OpenDungeon(d, bossName)` |
| Options in OneForAll's profile | `NewOptions`, `:Get`, `:Set`, `:OnChanged` |
| Its options on the Plugins page | `AddSettingsSection` |
| `/ofa run` | `RegisterSlashCommand` |
| Chat lines, safe calls, secret values | `Print`, `SafeCall`, `IsSecret` |
| Texts | `GetLanguage`, `Translate` (OneForAll's text when the plugin has none) |
| OneForAll's look | `Widgets.FramedPanel`, `CloseButton`, `Confirm`, `FontString`, `SetTexture` |
| Taking over data from the earlier built-in tracker (`-dt` builds), once | `GetCharacterData`, `GetOption`, `Copy` |

## Which dungeon

On `PLAYER_ENTERING_WORLD` and `ZONE_CHANGED_NEW_AREA` in a party or raid instance:
1. `GetInstanceInfo()` gives the instance ID.
2. `GetDungeonsByInstanceID(id)` gives the dungeons using it. Several where wings share an instance: Scarlet Monastery, Dire Maul, Blackrock Spire.
3. `FindCurrentDungeon()` chooses among them. When OneForAll is only guessing the wing (`sure == false`), the first wing is kept until a boss tells.
4. A boss of a sibling wing, seen alive or killed, makes that wing the run's dungeon (Lower / Upper Blackrock Spire, the Dire Maul wings…).

## Kills

WoW Forever doesn't let addons read the combat log, so kills come from several sources:

| Source | How |
|---|---|
| `ENCOUNTER_START` | Notes the fight's ID and the boss NPC IDs present (boss frames `boss1`–`boss5`, target). |
| `INSTANCE_ENCOUNTER_ENGAGE_UNIT` | Boss frames changed during the fight: their NPC IDs are added. |
| `ENCOUNTER_END` (success) | See *Matching an encounter* below. |
| `BOSS_KILL` | The fight's ID if already learned, else its name. |
| Units | Target, focus, mouseover, boss frames, nameplates, the group's targets (scanned once a second): a dead boss is a kill. |
| Loot | `GetLootSourceInfo`: a looted boss corpse is a kill. |

A unit's NPC ID comes from its GUID (`Creature-0-…-<npcID>-…`). Values the client marks as secret are skipped.

### Matching an encounter

OneForAll's boss names are English, and the client's encounter names are in its own language. On a successful `ENCOUNTER_END (id, name, …)`:

1. **Fight ID already learned** → that boss's NPC ID → ticked.
2. **The name matches** a boss: its English name, its translation, one of its aliases, or a name learned in the client's language → ticked, and the fight ID is learned.
3. **Bosses seen during the fight** (since `ENCOUNTER_START`) → ticked, and the fight ID and the encounter's name are learned.
4. **Nothing** → listed at the bottom under the client's name ("extra").

An extra disappears as soon as it can be tied to a boss, e.g. `BOSS_KILL` arrived before `ENCOUNTER_END`.

### Learned per account (`OneForAllDungeonTrackerDB`)

| Key | Content |
|---|---|
| `encounters[fightID]` | The boss's NPC ID. |
| `names[npcID]` | The boss's name in the client's language: from its unit name, or the encounter's name. |
| `log` | The last 300 log lines. |
| `debug` | `true` while `/ofa run debug` shows the log in the chat. |

Learned names are also used for display when OneForAll has no translation of a boss.

## Runs (`OneForAllDungeonTrackerCharDB.run`, per character)

| Field | Content |
|---|---|
| `id`, `key`, `name` | Instance ID, the dungeon's English name (OneForAll's key), the instance's name. |
| `since`, `active` | When the clock was last started, and the time counted before that. |
| `kills[bossName]` | Time of each kill, in seconds since the start. |
| `extra` | Kills that matched no boss, by the client's name. |
| `done`, `doneAt` | Final time and when the run ended. |
| `left` | When the player left the instance. |
| `xp`, `money` | XP and gold gained inside. |
| `hidden`, `manual`, `reset` | Window hidden for this run; opened with `/ofa run`; the instance was reset. |

When a new run starts:
- The instance ID differs from the saved run.
- The instance was reset (`INSTANCE_RESET_SUCCESS` in `CHAT_MSG_SYSTEM`).
- The player left more than 30 minutes ago (`RESUME`).
- A finished run was left, or ended more than 2 hours ago.
- A ticked boss is seen alive, at full health and with its own name. The name check matters: an entry for a group of mobs shares its NPC ID with the others of the group.

`PLAYER_LOGOUT` (also on `/reload`) pauses the clock without marking the run as left, so a reload never starts a new run.

## XP and gold

- **XP:** each `PLAYER_XP_UPDATE` adds the gain since the last reading. A level-up adds the end of the old level plus the start of the new one. XP from a quest turned in (`QUEST_TURNED_IN`) within 3 seconds before or after is taken off. At the level cap, or with XP turned off, the column isn't shown.
- **Gold:** `PLAYER_MONEY` adds gains only. Spending lowers the reference without lowering the total.

## The log

`R.Log(fmt, ...)` adds a timestamped line to `OneForAllDungeonTrackerDB.log`, always. Lines older than the last 300 are dropped. With `/ofa run debug`, each line is also printed in the chat.

| Logged | When |
|---|---|
| `in <instance> (instance <id>) as <dungeon>, new run` | Entering or changing zone. |
| `ENCOUNTER_START id=… name=…`, `boss1: npc …, <name>` | A boss fight starts. |
| `ENCOUNTER_END id=… name=… success=…`, `BOSS_KILL id=… name=…` | A boss fight ends. |
| `encounter <id>: boss <name> (<npcID>) seen as <unit>` | A boss is seen during the fight. |
| `name of <boss> (<npcID>): <client's name>` | A boss name is learned. |
| `kill by NPC …`, `kill by name …`, `kill not matched: …`, `extra … is …` | A kill is counted, or left unmatched. |

## Testing

- **Syntax:** `luac5.1 -p` on every file. The GitHub workflow does it on each push.
- **In game:** `/ofa run debug`, then a dungeon run. Then:
  - a `/reload` inside: the run must go on;
  - leave and come back;
  - reset the instance;
  - try with OneForAll in another language.
- After editing the `.toc`, restart the game: it is only read at startup.

## Contributing

- Code comments in English.
- New texts go into `Locales.lua` for the 4 languages. English is the key.
- Never write into what the API returns, and don't reach into OneForAll's own tables: everything goes through `OneForAllAPI`.
- Raise `## Version:` in the `.toc` and tag the release with the same version (`v1.0.2`).
