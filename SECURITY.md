# Security policy

## Supported versions

Only the latest release gets fixes.

| Version | Supported |
|---|---|
| Latest release (`1.0.1`) | ✅ |
| Earlier releases | ❌ |

## What counts as a security issue here

The Dungeon Tracker is a plugin. It reaches OneForAll only through the plugin API, and only writes its own saved variables:
- `OneForAllDungeonTrackerDB`, per account;
- `OneForAllDungeonTrackerCharDB`, per character;
- its options in OneForAll's profile, under `plugin.OneForAll_DungeonTracker.*`.

A security issue is, for example:
- the plugin writing anything else (OneForAll's data or saved variables, another addon's);
- text from the game (a boss, an instance or a chat message) that ends up run as code, or breaks the plugin's saved data;
- the log (`/ofa run debug`, saved in `OneForAll_DungeonTracker.lua`) storing more than names, IDs and times from the game.

Out of scope:
- **Issues in OneForAll with the plugin API:** report them to [OneForAll-API](https://github.com/Emzime/OneForAll-API/security).
- **Issues in OneForAll itself:** report them to its author on the [OneForAll Discord](https://discord.gg/JSPUqw4g).
- **A boss not ticked, or a wrong time:** these are ordinary bugs. Open an issue with the log (see the [user guide](docs/user-guide.md#a-boss-isnt-ticked)).

## Reporting

**Please don't open a public issue for a security problem.**

Use GitHub's private reporting: **Security and quality** tab → **Report a vulnerability**. Please include:
- the plugin's version and OneForAll's (`/ofa plugins`);
- what you did in the game, and what the plugin did or wrote;
- the log file if it helps (`WTF/Account/<account>/SavedVariables/OneForAll_DungeonTracker.lua`).

You'll get an answer within a week. Once the fix is released, the report is published with credit to you, unless you'd rather stay anonymous.
