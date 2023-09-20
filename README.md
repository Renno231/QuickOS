# GooberOS
This is a fork of OpenOS which automatically runs `/bin/main.lua` after booting. \
Opening terminal would require you to hold Ctrl + Shift on boot. You can even password protect it! \
GooberOS boots in about a second (without sacrificing functionality), while OpenOS takes 6 seconds.

## List of changes
1) A custom installer located at `/bin/install.lua` which can also upgrade your installation
2) Deleted a lot of `/bin/` scripts that I deemed unecessary (deleting their man pages too)
3) The entire boot sequence is just 3 files now instead of a big horde which was the culprit
4) A custom OS loading screen and an entire password system for accessing the terminal
5) Fallback LUA shell in case you goof up your `.shrc` or `/etc/profile.lua`

## Installation
Boot from an OpenOS floppy disk and enter `pastebin run 5qgkbkyc` into the command prompt. \
After that, just follow everything the installers tells you and you're good to go!
