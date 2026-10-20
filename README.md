# Zomboid
mods &amp; scripts for the game, Project Zomboid.
This script simply creates a local copy from steam mods you downloaded from workshop community.
It reads from your local setting file, default.txt, which defines the default load up mods in Zomboid, taking it as a reference list and copy from source(steam mods folder) to target(your targeting local path), and create a "control" mod that can enable these mods at one-click.
Fix path parameters in mod_merger.conf to your source & target.
Note that this script also alters each mod.info file in mod folders, in order to avoid conflict with original.
This might be buggy, use it cautiously.
