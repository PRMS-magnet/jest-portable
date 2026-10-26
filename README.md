# Jest-Portable - Jest Roblox for Lute

*Started: 2026-07-27 | Last major update: 2026-10-15 | Last updated: 2026-10-25*

Runs [Jest Roblox](https://github.com/Roblox/jest-roblox) 3.20.0 on
[Lute](https://github.com/luau-lang/lute), outside Roblox.

You can run this using [Luau Run](https://github.com/PRMS-magnet/luau-run) or your own test runner.

[Getting started](https://github.com/PRMS-magnet/luau-run/blob/main/docs/getting-started.md)
installs Luau Run and runs a first spec.

## Status

| area | state |
|---|---|
| Jest specs on Lute | supported, through Luau Run |
| Jest specs in Roblox Studio | supported, through Luau Run |
| Windows, x64 | tested |
| macOS and Linux | not tested |

Tested on Windows 10 (build 19044) with Lute `1.0.1-nightly.20260729`.

## What changed from Jest Roblox

- Every require is a relative path inside the tree, so the same files load on
  Lute and in Roblox Studio. The tree is one pesde package,
  `prms_magnet/jest_portable` at version 0.3.0, not published to the pesde
  registry.
- Where Jest Roblox calls Roblox's globals, such as `task`, `warn` and
  `game:GetService`, the packages use a runtime provider instead.
  `jest_portable_runtime` has one for Lute and one for Roblox, and `Lute.luau`
  and `Roblox.luau` at the root start the runtime with theirs.
- jest-circus keeps a failure's stack frames, so the failure names its file and
  line.
- `jest_portable` adds `StandaloneResult`, which runs one spec file and writes
  its result for Luau Run to read.

## Limitations

- **Snapshots cannot be written yet.** `toMatchSnapshot` fails for a snapshot
  that does not exist.
- **`runCLI` is untested on Lute.** Luau Run finds the spec files and runs each
  one through `StandaloneResult` instead.

## Credits

[Jest Roblox](https://github.com/Roblox/jest-roblox) is Roblox's port of [Jest](https://github.com/jestjs/jest). The
packages also include Roblox's ChalkLua, LuauPolyfill, Picomatch, ReactIs,
RegExp and Symbol, and Promise by Eryn L. K. PRMS made the changes for Lute.

## License

[MIT](LICENSE). Each package in `packages/` keeps its own upstream license
file.

[AI Policy](https://gist.github.com/PRMS-magnet/2e7588fb66cf472c634589064d8a799d)
