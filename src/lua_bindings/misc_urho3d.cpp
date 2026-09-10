// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include "client/config.h"
#include "interface/fs.h"
#include <tolua++.h>
#include <Context.h>
#include <Scene.h>
#include <Profiler.h>
#include <ResourceCache.h>
#define MODULE "lua_bindings"

namespace magic = Urho3D;

extern client::Config g_client_config;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace lua_bindings {

#define GET_TOLUA_STUFF(result_name, index, type) \
	if(!tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
		tolua_error(L, __PRETTY_FUNCTION__, &tolua_err); \
		return 0; \
	} \
	type *result_name = (type*)tolua_tousertype(L, index, 0);
#define TRY_GET_TOLUA_STUFF(result_name, index, type) \
	type *result_name = nullptr; \
	if(tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
		result_name = (type*)tolua_tousertype(L, index, 0); \
	}

static int l_profiler_block_begin(lua_State *L)
{
	const char *name = lua_tostring(L, 1);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	Profiler *profiler = context->GetSubsystem<magic::Profiler>();
	if(profiler)
		profiler->BeginBlock(name);

	return 0;
}

static int l_profiler_block_end(lua_State *L)
{
	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	Profiler *profiler = context->GetSubsystem<magic::Profiler>();
	if(profiler)
		profiler->EndBlock();

	return 0;
}

// add_resource_dir(path: string) -> bool
//
// Puts a directory on Urho3D's resource search path, so that files written
// there can be asked for by name. Urho3D's own Lua bindings do not expose
// this, and the Luanti client extension needs it for the media a server sends.
//
// Only directories under the client's cache path are allowed. A resource dir
// is readable by everything the client draws, including sandboxed game code,
// so this is not a general "put any directory on the search path" call.
static int l_add_resource_dir(lua_State *L)
{
	ss_ path = interface::fs::get_absolute_path(lua_checkcppstring(L, 1));
	ss_ cache_path = interface::fs::get_absolute_path(
			g_client_config.get<ss_>("cache_path"));
	if(path.substr(0, cache_path.size()) != cache_path)
		return luaL_error(L, "add_resource_dir(): \"%s\" is not under the "
				"cache path", path.c_str());
	if(!interface::fs::path_exists(path))
		return luaL_error(L, "add_resource_dir(): \"%s\" does not exist",
				path.c_str());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	ResourceCache *rc = context->GetSubsystem<magic::ResourceCache>();
	bool ok = rc->AddResourceDir(path.c_str());
	if(ok)
		log_v(MODULE, "add_resource_dir(): \"%s\"", cs(path));
	else
		log_w(MODULE, "add_resource_dir(): \"%s\" failed", cs(path));
	lua_pushboolean(L, ok);
	return 1;
}

void init_misc_urho3d(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(profiler_block_begin);
	DEF_BUILDAT_FUNC(profiler_block_end);
	DEF_BUILDAT_FUNC(add_resource_dir);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
