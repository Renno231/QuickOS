## Installation
Boot from an OpenOS floppy disk and enter `pastebin run id5ZWJp8` into the command prompt. \
After that, just follow everything the installers tells you and you're good to go!

# QuickOS
This is QuickOS, a fork of GooberOS (which is a fork of OpenOS). The aim of this project is to create a stable, performant, and production-ready foundation for OpenComputers programs.
Currently QuickOS (QOS) additionally features a headless boot process.
The primary feature of QuickOS, that is shared with GooberOS, is boot time of about 1 second (without sacrificing functionality), while OpenOS takes 6 seconds.
The plans of this project are as follows:
add an operating system configuration system to allow for greater programmatic control of the OS and features
a configurable automatic update system
an optimized installation process aiming for a speedy installation
a headless installation

## List of changes
1) A custom installer located at `/bin/osinstall.lua` with a snappy UI and very modular configuration options
2) A powerful custom toolkit of software made by Renno231 in the `/usr/bin` and `/usr/lib` directories
3) Note: some of the tools in the QuickOS toolkit (line above) may not be fully tested or complete.
4) Man page files are now optional and default to not included in the installation process
5) The entire boot sequence has been optimized to minimize boot speed at the expense of the /boot/ system
6) A custom OS loading screen and an entire password system for accessing the terminal
7) Fallback LUA shell in case you goof up your `.shrc` or `/etc/profile.lua`
