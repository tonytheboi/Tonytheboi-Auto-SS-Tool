# Tonytheboi Auto Screenshare

Includes everything needed for a normal SS, just makes your life easier.

One PowerShell script that runs the standard Minecraft screenshare checks automatically, gives a suspicion score with the reasons behind it, saves a full HTML report to the Desktop, and launches the usual SS tools from one menu.

> **The score is not proof.** It is a weighted summary of the automated checks, not a measured chance of cheating. Always read the reasons under it and confirm them yourself before banning anyone.

## Run it

Open **CMD as administrator** and paste:

```
powershell -ExecutionPolicy Bypass -Command "Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/tonytheboi/Tonytheboi-Auto-SS-Tool/main/TonytheboiAutoScreenshare.ps1')"
```

Or download `TonytheboiAutoScreenshare.ps1` and run:

```
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\Downloads\TonytheboiAutoScreenshare.ps1"
```

**Requirements:** Windows 10 or 11, administrator rights. Keep Minecraft open during the SS: several checks only work on the running game.

## What it checks

Option **[1]** runs everything below and opens the report.

| Option | Check | Looks for |
|---|---|---|
| 2 | System and Minecraft | Recent reboot or relaunch, unknown `-javaagent` / native agents, `DisableAttachMechanism`, unsigned DLLs injected into `javaw`, JNativeHook (Java autoclickers) |
| 3 | Services | SysMain, PcaSvc, EventLog, DPS, DiagTrack, DusmSvc and BAM stopped, disabled, or changed since boot |
| 4 | Secure Boot | Secure Boot off, test signing, disabled driver integrity checks |
| 5 | Event logs | Security / System logs cleared, or logs that start suspiciously recently |
| 6 | PowerShell history | Deleting, downloading, log wiping and service commands |
| 7 | Prefetch | Prefetch cleared or disabled, recently run programs, suspicious names |
| 8 | BAM | Programs run in the last 7 days: unsigned, deleted after running, or run from odd folders |
| 9 | USN journal | Journal deleted or recreated, deleted jars / exes / prefetch files |
| 10 | Executed jars | Jars loaded by Java (from Prefetch), jars opened by double-click, Java crash logs |
| 11 | Mods and versions | Mods folder of the **running** instance: new, hidden, non-jar and leftover files; game version checked against Mojang's published hash |
| 12 | Misc | Defender exclusions, Recycle Bin, recent executables in Downloads / Desktop / Temp, running clickers and macro software |
| 13 | Extra | Startup entries, JNativeHook leftovers, USB drives |

Results are marked **FLAG** (strong red flag), **WARN** (look closer / ask the player), **OK** or **INFO**.

Known-normal things are recognised and not flagged, including the Modrinth App's `theseus.jar` agent (contents verified), Java's `zipfstmp*.tmp` leftovers (matched to their mod), Simple Voice Chat's audio libraries, and official Mojang snapshot / April Fools versions.

## Built-in tools menu

| Key | Tool | Source |
|---|---|---|
| S | Services check | [praiselily/lilith-ps](https://github.com/praiselily/lilith-ps) |
| M | Mod analyzer | [YarpLetapStan/PowershellScripts](https://github.com/YarpLetapStan/PowershellScripts) |
| J | P1AE javaw memory scanner (game must be open) | [p1aegg/javaw](https://github.com/p1aegg/javaw) |
| P | Prefetch Parser | [spokwn/prefetch-parser](https://github.com/spokwn/prefetch-parser) |
| A | BAM parser | [spokwn/BAM-parser](https://github.com/spokwn/BAM-parser) |
| W | WinPrefetchView | [NirSoft](https://www.nirsoft.net/utils/win_prefetch_view.html) |
| L | LastActivityView | [NirSoft](https://www.nirsoft.net/utils/computer_activity_view.html) |
| K | System Informer (only runs if signed by Winsider) | [winsiderss/systeminformer](https://github.com/winsiderss/systeminformer) |
| C | Cleanup: removes everything the tool downloaded | — |

These tools are downloaded from their official pages each time; nothing is bundled here. They belong to their authors.

## Privacy and safety

- **Read-only.** The checks only read the PC. Nothing is deleted or changed, except option **[C]**, which removes only what this tool downloaded.
- **Nothing is sent anywhere.** The report is saved to the Desktop of the PC being checked and nowhere else. The script contains no upload code.
- **Third-party tools** run their own code: the mod analyzer, for example, sends mod file hashes to Modrinth to identify them.

## Before you ban

- A single WARN is a lead, not a verdict. Ask the player about it.
- The memory scan, mod analyzer and kernel dump are not part of the score. Run them and weigh them yourself.
- Write down what you found, where, and when (path, time, tool). Appeals go much better with evidence than with "the tool flagged him".
