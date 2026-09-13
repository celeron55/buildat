--
-- Constants values for use with the Lua API
--

-- mapnode.h
-- Built-in Content IDs (for use with VoxelManip API)
-- MODIFIED for buildat: content ids are allocated by whichever engine runs
-- the game, and here builtin/luanti is that engine. lua/bootstrap.lua has
-- already set these to the numbers its VoxelRegistry uses; leaving Luanti's
-- own 125/126/127 here would overwrite them with numbers nothing else means.
-- See doc/plan/luanti_module_plan.md, "the ids are the same number".

-- emerge.h
-- Block emerge status constants (for use with core.emerge_area)
core.EMERGE_CANCELLED   = 0
core.EMERGE_ERRORED     = 1
core.EMERGE_FROM_MEMORY = 2
core.EMERGE_FROM_DISK   = 3
core.EMERGE_GENERATED   = 4

-- constants.h
-- Size of mapblocks in nodes
core.MAP_BLOCKSIZE = 16
-- Default maximal HP of a player
core.PLAYER_MAX_HP_DEFAULT = 20
-- Default maximal breath of a player
core.PLAYER_MAX_BREATH_DEFAULT = 10

-- light.h
-- Maximum value for node 'light_source' parameter
core.LIGHT_MAX = 14
