# Plan: client preferences

**Built 2026-09-12** on branch `client-preferences`. Nothing here is open
except the screen that sets them, which is a bonus item in
`doc/plan/master_plan.md`. What the file is for now is the fence it was built
around and the list of what deliberately stays out, both of which govern
whatever gets added next.

Three things about the build that are not obvious from the plan below:

- **The UI sprite won.** A `BorderImage` on the UI root at priority -10000,
  disabled so it takes no input, sized in UI coordinates rather than window
  pixels because the UI scale has already divided those down. No second
  viewport was needed.
- **The saved file is read through the same parser as `-o`**, so the range
  checks are written once. A missing field keeps its default; a field that is
  present and out of range drops the whole set back to the defaults and says
  so.
- **`max_fps` defaults to 200**, which is Urho3D's own desktop default, so
  leaving it alone changes nothing.

Preferences the user sets once and every game honours, whatever it is:
how big the frame is computed, how often it is presented, and how loud it
is. Undersampling of the 3D render was the one that was asked for; the rest
ride along because the plumbing that carries one preference carries six.

The fence this plan is built around: **the client decides how much the frame
costs and how loud it is; it never decides what the art is.** A voxel game
whose direction is nearest-filtered texels, a game that appends its own
tonemap, a game that sets its own shadow map size and a game with a full
mixer of its own all keep exactly what they set -- scaled, in the audio case,
by what the user asked for.

### "Preferences", not "settings"

The word is worth picking deliberately because the codebase has already spent
the other one. `core::Config` *is* the settings system -- `share_path`,
`cache_path`, `boot_to_menu`, `server_address`, the `-P`/`-C`/`-U` flags --
and it holds deployment facts rather than taste. What this plan adds is the
other kind: what one person likes, on one machine, persisted between runs.
Calling it preferences keeps `g_client_config` meaning what it already means
and gives the new thing a name that does not collide in conversation or in
code. The file is `user_path/preferences.json`.

## The preferences

| preference | what it does | what it may not change | where it already exists |
| --- | --- | --- | --- |
| `render_scale` | 3D viewports rendered at `scale x` window size, UI at native | what a pixel is | nothing |
| `vsync` | present synchronised to the display | nothing | `GraphicsOptions::vsync`, hardcoded `true` |
| `max_fps` | frame limiter | nothing | nothing; Urho3D's `Engine::SetMaxFps` |
| `multisampling` | MSAA samples | edges only | `GraphicsOptions::multisampling`, hardcoded `1` |
| `sound_volume` | a gain every sound is multiplied by | a game's own mix, which multiplies with it | `Audio::SetMasterGain` |
| `sound_mute` | that gain forced to zero | the same | the same |

Five of the six are one field each and already exist or are one Urho3D call.
`render_scale` is the whole of the work.

**Deliberately not in this**, because each one changes what the art looks
like and the game is the one that should say:

- shadow map size, shadow quality, `drawShadows` -- `extensions/luanti_client`
  sets all three itself, and softness is art direction.
- texture quality (mip skip), material quality (shader variants), texture
  filter mode, anisotropy -- a voxel game wants nearest where a model game
  wants trilinear.
- FOV, draw distance, view range. These are game concepts. A client-side
  draw distance would silently change what a player can see, which is a
  gameplay difference and not a graphics setting.
- HDR on/off. Games choose it per viewport and their lighting is calibrated
  for the tonemap that follows.

If a shadow cap or a quality preset is wanted later, the place for it is a
*ceiling* the game's own setting is clamped to, and that wants its own
discussion rather than being smuggled in here.

## How undersampling gets applied

The games make their own viewports, in sandboxed Lua:

    local viewport = magic.Viewport:new(scene, camera_node:GetComponent("Camera"))
    magic.renderer:SetViewport(0, viewport)
    -- and then, in most of them, the renderPath is replaced:
    local rp = viewport.renderPath:Clone()
    rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
    ...
    viewport.renderPath = rp

Eleven games and `extensions/luanti_client` do some version of that. So the
question is how a user's preference reaches a viewport the game owns.

**The answer is to ask the game, not to take the viewport off it.** The
engine offers one call that a game uses *instead of*
`renderer:SetViewport()`, and what it gets back is its scene drawn at the
size the user asked for, composited to the screen by the engine:

    -- instead of magic.renderer:SetViewport(0, viewport)
    magic.set_preferred_viewports({viewport})

**"Preferred" is the word that carries the whole idea**, and it is worth
spending it: these are the viewports drawn the way the user's graphics
settings ask for, as against the raw `Renderer` ones which are drawn the way
the game says and nothing else. A game reading its own code a year later can
tell which it picked from the name alone, which is the only documentation
that is always present.

The game keeps the viewport object and everything it does to it afterwards
-- including replacing `renderPath`, which is what most of them do -- because
the engine changes where the viewport is drawn, not what it draws. Under the
call, the viewport goes onto a `Texture2D` of
`round(w*scale) x round(h*scale)` with `TEXTURE_RENDERTARGET`, and the engine
draws that texture under the UI. Urho3D draws the UI to the backbuffer after
the viewports, so **the UI is never undersampled**.

At `render_scale == 1.0` the call is `renderer:SetViewport()` and nothing
else: no texture, no blit, the frame the client draws today. That is the
state every existing screenshot was taken in and the state tests run in.

### Why cooperative rather than forced

The alternative was for the engine to reach into `Renderer`, take whatever
viewports it found there and redirect them itself, once a frame. That works,
and it has the one advantage that a game cannot fail to honour the setting.
It is worse everywhere else:

- **It has to guess.** A viewport on the renderer might be the main 3D view
  or it might be something the game set up for its own reasons. The engine
  would be deciding on the game's behalf what a viewport is for.
- **It has to keep checking**, because a game can call `SetViewport` at any
  time and `renderer.numViewports = 0` on teardown -- which
  `extensions/luanti_client` does. That is a per-frame scan whose only job is
  noticing that something changed.
- **It cannot be opted out of per viewport.** A game with a scope render, a
  security-camera feed or a pixel-exact minimap has no way to say "this one
  at native resolution, the main view scaled".

The cooperative version deletes the scan, deletes the guessing, and the
opt-out is just not calling it. What it costs is that a game can ignore the
setting -- which is the correct amount of authority for a client preference
to have over a game's rendering, and the same amount `buildat.set_ui_scale()`
already has.

### What it does not expose

Not a `RenderSurface`, and not the texture. `render_scene_to_texture()`
already settled this for thumbnails -- "one function rather than
RenderSurface, its update modes and the texture formats" -- and the same
reasoning holds here: what a game needs is for its scene to end up on the
screen at the right size, and the compositing is the part that should not be
written twice in eleven games. If a game ever genuinely needs the buffer,
exposing it is a later, separate decision.

### The surface

Two calls:

    magic.set_preferred_viewports(list)    -- renderer:SetViewport() + numViewports
    buildat.get_preferred_render_scale()   -- for a game that wants to know

The list is plural on purpose. Urho3D needs both a viewport per slot and a
count, and passing the whole set says both at once:

    magic.set_preferred_viewports({viewport})            -- one view
    magic.set_preferred_viewports({vp_top, vp_bottom})   -- bomber_drone
    magic.set_preferred_viewports({})                    -- teardown

So there is no `set_num_preferred_viewports()` to name badly, no index
arithmetic at the call site, and teardown -- which `extensions/luanti_client`
does on disconnect -- is an empty table rather than a second call that has to
be remembered. It is declarative: this is what is on the screen now.

`get_preferred_render_scale()` sits beside `buildat.get_ui_scale()`, which is
the existing precedent for a client preference a game can read. The viewport
call goes in `extensions/urho3d/init.lua` beside `render_scene_to_texture`,
wrapped the same way, with a `__buildat_` C function under it.

Multiple viewports keep their rects, scaled by the same factor onto the
shared texture; `games/bomber_drone`'s two are the same code path as one.
`RenderSurface::SetNumViewports()` exists. Viewport rects stay in backbuffer
pixels from the game's point of view, so nothing about screen-to-world
maths, picking or the `look` command changes.

Considered and not taken: a `magic.prefs.*` / `buildat.prefs.*` namespace,
which would make the noun do the work and let the functions be plain
`set_viewports()`. It reads well and `set_ui_scale()`/`get_ui_scale()` would
eventually want to move into it -- which is exactly why it is not this
change. The flat names match everything else in `client/api.lua` today.

Left to settle while building: whether a UI sprite is the cheapest way to
get the texture onto the backbuffer, or whether a second scene-less viewport
with a one-command renderPath is better. Try the sprite first; it is fewer
moving parts.

Converting the in-tree games is a line each, and is worth doing as part of
this rather than later: eleven games plus `extensions/luanti_client` is also
eleven checks that the mechanism works on a real renderPath.

## How the volume gets applied

The opposite of `render_scale`: **enforced, and free.** Urho3D's `Audio`
keeps a gain per sound type and multiplies the type's gain by the `"Master"`
one -- `Audio::GetSoundSourceMasterGain()` returns `master * type`
(`Audio.cpp:257`). So the client sets `"Master"` from the preference and
every sound in every game is already scaled by it, with a game's own mixing
happening in the type gains underneath. Mute is the same call with zero.
There is no extra mixing step to write: the one that was wanted is already
in the engine.

**The one change that makes it enforcement rather than a default.** The
sandbox hands games `magic.audio:SetMasterGain(type, gain)` with the type as
a free string (`extensions/urho3d/safe_classes.lua:1318`), so a game can
write `"Master"` and stomp the user. The wrapper therefore **refuses
`"Master"` from sandboxed code** -- games have `"Effect"`, `"Music"`,
`"Ambient"` and `"Voice"`, which is what per-type gains are for, and the
master belongs to the client. One condition in one wrapper, and the
enforcement is exact rather than advisory.

The asymmetry is worth stating plainly rather than apologising for: the
volume is enforced because the engine already multiplies in the right place,
and `render_scale` is cooperative because a viewport belongs to the game
that made it. The rule is the same in both -- the client owns the cost, the
game owns the content -- and only the mechanism differs.

Deliberately not in this: per-type volumes, positional audio parameters, a
device chooser, anything resembling a mixer. A game with a mixer of its own
keeps it and it multiplies with the master; a client-side mixer would be two
mixers disagreeing.

A game that wants to *show* the user's volume on a slider of its own needs a
getter, the way `get_preferred_render_scale()` exists. Not in the first cut;
nothing needs it until a game draws an options screen.

## How it is configured

**A file.** `GraphicsOptions` is already persisted -- `cache_path/window.json`
holds size, fullscreen and maximized, loaded by `load_window_state()`. The
new preferences are fields beside them: one more `json_object_get` in load,
one more set in save.

`doc/plan/world_persistence_plan.md` moves that file. A preference is not cache
-- the cache is what the program can recreate by itself -- so it becomes
**`user_path/preferences.json`**, holding the window geometry, the four
frame preferences and the two sound ones. Since it is moving anyway the
rename is free, and the old name described half of half of what it now
holds.

`GraphicsOptions` keeps its name as the struct handed to
`Graphics::SetMode()`; the sound pair sits beside it rather than inside it.
The file is preferences, the struct is a display mode.

**A command line flag**, for a test run and for a user whose setting has made
the client unusable:

    bin/buildat -o render_scale=0.5,vsync=0,sound_mute=1

One repeatable `-o` taking `k=v[,k=v...]` -- `-o` for option, because `-g`
for graphics stopped being the right letter when the sound arrived. An
explicit `-o` **wins over the file and is not written back**, the same rule
`-w` already follows ("came from the command line, so it is not
remembered").

**No UI in this round.** `extensions/__menu` is Lua and already draws menus,
so a page of sliders is a small job -- it needs a Lua call that writes a
preference and persists it, which is the reason the C++ side is the authority
for these and not the sandbox. But it is deliberately not here: the file and
`-o` are the interface, and a preference nobody can find is still honoured by
every game. The screen is a bonus item in `doc/plan/master_plan.md`, to pick up
when something else is stalled or done.

## How tests stay unaffected

Two rules, both one sentence, because a rule that needs explaining gets
forgotten:

1. **`-c` ignores the saved file entirely** and runs on the built-in
   defaults. A preference a developer left at `render_scale=0.5` can then
   never change what a screenshot looks like, and the failure mode where two
   runs of `games/voxel_lighting/check.txt` differ for a reason nobody wrote
   down cannot happen.
2. **`-o` still wins**, on a `-c` command line as much as anywhere else,
   which is how a preference itself gets tested.

and one default worth choosing rather than inheriting: **a `-c` run is muted
unless `-o` says otherwise.** Nothing captures audio, screenshots do not
change, and a test run that plays a game's music through the developer's
speakers is a small recurring annoyance with no upside.

`-w WxH` already fixes the window size for comparable images; the scale is
relative to that, not to the desktop, so the two compose.

The check this leaves behind, beside `check_pick_default_window_size()` in
`src/client/app.cpp`: an assert-based self-check of the `-o` parse
(including a malformed value) and of the scaled-size arithmetic -- rounding,
a minimum of one pixel, and a second viewport's rect scaled by the same
factor.

The visual check is a line in `games/voxel_lighting/README.txt`: run
`check.txt` at `-o render_scale=0.5` and again at `1.0`; the same scene,
one softer, and the UI text equally sharp in both.

## Other workflows that have to keep working

Collected because each one is a way this can go wrong quietly:

- **Screenshots** (`-c ... screenshot`) are taken from the backbuffer after
  3D and UI, so they stay at window resolution whatever the scale is.
- **`look` and injected mouse input** are relative and camera-based. Keeping
  the viewport rect in backbuffer pixels is what keeps them untouched.
- **Thumbnails** -- `render_scene_to_texture()`, which `games/aggregate`'s
  structures menu wears. Outside the mechanism by construction.
- **Two viewports** -- `games/bomber_drone`.
- **Teardown** -- `extensions/luanti_client` sets `renderer.numViewports = 0`
  on disconnect. It becomes `set_preferred_viewports({})`, and zero viewports
  must not leave a stale frame on screen.
- **A game that never calls it** keeps working exactly as it does now, at
  native resolution. That is the deal, and the docs should say so plainly
  rather than treating it as a bug to be closed later.
- **HDR and appended post-process** -- `luanti_client`, `aggregate`,
  `aggregate_look`, `digger`, `infidigger`, `undermine`, `voxel_lighting`,
  `voxel_physics`, `multisection_lighting`, `bomber_drone`. Untouched, which
  is the main reason for the chosen approach.
- **Window resize and fullscreen toggle mid-session**: the texture is
  reallocated from `E_SCREENMODE`.
- **UI scale** (`-u` / `ui_scale`) stays independent -- the UI is not scaled
  and the two settings must not be confused for each other in the docs.
- **The launch menu's own 3D scene** -- `extensions/__menu` is the one place
  where opting out is probably right, and with a cooperative call opting out
  is simply not calling it.

Not in this plan: the screen that sets any of it. See "Bonuses" in
`doc/plan/master_plan.md`.
