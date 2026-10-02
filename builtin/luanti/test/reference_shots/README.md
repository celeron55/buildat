# The reference shot set

This directory is the recipe; the pictures land in `local/reference_shots/`
(and the generated world in `local/reference_worlds/`). One world, eight
viewpoints, twenty-three pictures a client, taken by three clients so their
rendering can be compared: official Luanti, `extensions/luanti_client`, and
`builtin/luanti` with `apps/vanilla`. The plan is
`doc/plan/rendering_plan.md`, [OFFICIAL_SHOTS] and [REFVIEWS_MOD].

## Which file holds which decision

| file | owns |
| --- | --- |
| `map_meta.txt` | the world: seed and mapgen settings, Luanti's own format |
| `set.lua` | the viewpoints, the hours, the weather, the range, the hold, the probe crops |
| `runner.lua` | what the fixture does with them; holds no numbers |
| `luanti.conf` | official Luanti's pinned settings, minus what `set.lua` owns |
| `mod.conf` | the fixture's name as a worldmod |
| `build.sh` | makes every copy the runners need; the only file that may |
| `shoot_luanti_server.sh` | `luanti --server` plus one Luanti client: `CLIENT=luanti` or `extension` |
| `shoot_buildat_server.sh` | `buildat_server` plus the launcher, one client per mode |
| `probes.sh` | reads the finished pictures and prints the table |
| `pathtrace.sh`, `pathtrace_render.py` | the path-traced reference, [PATH_TRACE_REF] |

Nothing `build.sh` writes is committed. It emits, into a directory the
caller names, the fixture as a worldmod (`refviews/`), the same fixture as
one file (`fixture.lua`, for `BUILDAT_LUANTI_LUA`), official Luanti's
config with the frame and the range appended, and `env.sh` with the seed,
the frame, the range and the probe crops for the shell.

## What to run, in what order

1. `shoot_luanti_server.sh reference` -- generates the world into the cache
   if it is not there, and takes official Luanti's `official_shadows` set.
   `MODE=unlit` for `official_unlit`; `CLIENT=extension` for the extension's.
   Needs the desktop and the patched client (see the file's header).
2. `shoot_buildat_server.sh unlit shadows pbr` -- one server, a client per
   mode, `module_<mode>` sets. `PROBE=1` for the short cycle.
3. `probes.sh` -- the table, each set against its reference.
4. `pathtrace.sh` -- the dumps and the Cycles renders, `pathtrace_r<RANGE>`.
   Never while a server or a client is up: Blender takes the machine.

Every set is `<client>_<mode>_r<RANGE>`. `REFSHOT_SHOTS_DIR` and
`REFSHOT_WORLDS_DIR` move the two roots; `RANGE`, `HOLD`, `PROBE`,
`PATHTRACE` and `CYCLES` are the run's parameters and go through `build.sh`.
