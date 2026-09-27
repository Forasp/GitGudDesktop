# GitGud Desktop

A Git client you can reshape. The engine is native C++ over libgit2; the
interface above it (layouts, skin, menus, shortcuts, workflows) is XML and
Lua that reloads while the app runs, so you can restyle it, rearrange it, or
build your own features without recompiling. Works with any Git server; no
account required.

## Getting started

1. Download `GitGud-win64.zip` from the
   [latest release](https://github.com/Forasp/GitGudDesktop/releases/latest).
2. Unzip it anywhere and run `gitgud.exe`. Nothing to install.
3. Pick an interface, then add a repository: clone one, create one, or open a
   folder you already have.

Windows, 64-bit.

## Two prebuilt interfaces, or build your own

A default interface in the GitHub Desktop tradition, and one laid out like
Perforce's P4V.

![The default interface behind the P4V-style interface](.github/images/ui-interfaces.png)

See [Modding ▸ Your own interface](https://github.com/Forasp/GitGudDesktop/wiki/Modding#9-your-own-interface).

## Documentation

Everything lives in the **[wiki](https://github.com/Forasp/GitGudDesktop/wiki)**:
[Modding](https://github.com/Forasp/GitGudDesktop/wiki/Modding) ·
[Lua API](https://github.com/Forasp/GitGudDesktop/wiki/Lua-API) ·
[Building](https://github.com/Forasp/GitGudDesktop/wiki/Building) ·
[Using the Default UI](https://github.com/Forasp/GitGudDesktop/wiki/Using-the-Default-UI) ·
[Using the P4V UI](https://github.com/Forasp/GitGudDesktop/wiki/Using-the-P4V-UI) ·
[Principles](https://github.com/Forasp/GitGudDesktop/wiki/Principles)

## Build

Windows, Visual Studio 2022+ (C++ workload), and Git:

```powershell
.\setup.cmd
```

That sets up the dev environment, the CEGUI submodule and its build, and the
app. See [Building](https://github.com/Forasp/GitGudDesktop/wiki/Building)
for presets, tests, and packaging.

## License

[MIT](LICENSE)
