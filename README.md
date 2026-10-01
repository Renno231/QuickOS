# QuickOS
QuickOS (QOS) is a lightweight operating system for OpenComputers, focused on fast startup and a stable, performant foundation for programs. It includes a headless boot process and a custom toolkit of commands and libraries.

## Installation
Start from a bootable OpenComputers environment with a Lua shell, the `pastebin` command, and internet access. Run:

```sh
pastebin run id5ZWJp8
```

Then follow the QuickOS installation wizard.

## Features
1) A custom installer located at `/bin/osinstall.lua` with a snappy UI and very modular configuration options
2) A powerful custom toolkit of software made by Renno231 in the `/usr/bin` and `/usr/lib` directories
3) Note: some of the tools in the QuickOS toolkit (line above) may not be fully tested or complete.
4) Man page files are now optional and default to not included in the installation process
5) An optimized boot sequence designed to minimize startup time without a separate `/boot/` system
6) A custom OS loading screen and an entire password system for accessing the terminal
7) Fallback LUA shell in case you goof up your `.shrc` or `/etc/profile.lua`

## Roadmap
- An operating system configuration system for greater programmatic control of the OS and its features
- A configurable automatic update system
- A faster installation process
- Headless installation
