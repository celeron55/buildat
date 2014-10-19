// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include "interface/atlas.h"
#include <luabind/luabind.hpp>
#include <luabind/pointer_traits.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/raw_policy.hpp>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Scene.h>
#include <Context.h>
#pragma GCC diagnostic pop
#define MODULE "lua_bindings"

using interface::AtlasRegistry;

namespace lua_bindings {

sp_<AtlasRegistry> createAtlasRegistry(lua_State *L)
{
	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Urho3D::Context *context = buildat_app->get_scene()->GetContext();

	return sp_<AtlasRegistry>(
			interface::createAtlasRegistry(context));
}

void init_atlas(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<AtlasRegistry, bases<>, sp_<AtlasRegistry>>("AtlasRegistry")
			.def("update", &AtlasRegistry::update),
		def("createAtlasRegistry", &createAtlasRegistry)
	];
}

} // namespace lua_bindingss

// codestyle:disable (currently util/codestyle.sh screws up the .def formatting)
// vim: set noet ts=4 sw=4:
