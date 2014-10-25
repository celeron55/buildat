// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include <tolua++.h>
#include <Context.h>
#include <Scene.h>
#include <Profiler.h>
#define MODULE "lua_bindings"

namespace magic = Urho3D;

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

void init_misc_urho3d(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(profiler_block_begin);
	DEF_BUILDAT_FUNC(profiler_block_end);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
