// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/voxel.h"
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/pointer_traits.hpp>
#define MODULE "lua_bindings"

#define DEF_METHOD(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setfield(L, -2, #name); \
}

using interface::VoxelInstance;
using interface::VoxelRegistry;

/*namespace luabind {
namespace detail {
namespace has_get_pointer_ {
	template<class T>
	T * get_pointer(std::shared_ptr<T> const& p) { return p.get(); }
} // has_get_pointer_
} // detail
} // luabind*/

namespace lua_bindings {

/*struct LuaVoxelRegistry
{
	static constexpr const char *class_name = "VoxelRegistry";
	sp_<VoxelRegistry> internal;

	LuaVoxelRegistry():
		internal(interface::createVoxelRegistry())
	{}
	static int gc_object(lua_State *L){
		delete *(LuaVoxelRegistry**)(lua_touserdata(L, 1));
		return 0;
	}
	static int l_serialize(lua_State *L){
		LuaVoxelRegistry *o = internal_checkobject(L, 1);
		std::ostringstream os(std::ios::binary);
		o->internal->serialize(os);
		ss_ s = os.str();
		lua_pushlstring(L, s.c_str(), s.size());
		return 1;
	}
	static int l_deserialize(lua_State *L){
		LuaVoxelRegistry *o = internal_checkobject(L, 1);
		ss_ s = lua_checkcppstring(L, 2);
		std::istringstream is(s, std::ios::binary);
		o->internal->deserialize(is);
		return 0;
	}

	static LuaVoxelRegistry* internal_checkobject(lua_State *L, int narg){
		luaL_checktype(L, narg, LUA_TUSERDATA);
		void *ud = luaL_checkudata(L, narg, class_name);
		if(!ud) luaL_typerror(L, narg, class_name);
		return *(LuaVoxelRegistry**)ud;
	}
	static int l_create(lua_State *L){
		LuaVoxelRegistry *o = new LuaVoxelRegistry();
		*(void**)(lua_newuserdata(L, sizeof(void*))) = o;
		luaL_getmetatable(L, class_name);
		lua_setmetatable(L, -2);
		return 1;
	}
	static void register_metatable(lua_State *L){
		lua_newtable(L);
		int method_table_L = lua_gettop(L);
		luaL_newmetatable(L, class_name);
		int metatable_L = lua_gettop(L);

		// hide metatable from Lua getmetatable()
		lua_pushliteral(L, "__metatable");
		lua_pushvalue(L, method_table_L);
		lua_settable(L, metatable_L);

		lua_pushliteral(L, "__index");
		lua_pushvalue(L, method_table_L);
		lua_settable(L, metatable_L);

		lua_pushliteral(L, "__gc");
		lua_pushcfunction(L, gc_object);
		lua_settable(L, metatable_L);

		lua_pop(L, 1); // drop metatable_L

		// fill method_table_L
		DEF_METHOD(serialize);
		DEF_METHOD(deserialize);

		// drop method_table_L
		lua_pop(L, 1);
	}
};

static int l_VoxelRegistry(lua_State *L)
{
	return LuaVoxelRegistry::l_create(L);
}*/

void init_voxel(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}
	//LuaVoxelRegistry::register_metatable(L);
	//DEF_BUILDAT_FUNC(VoxelRegistry);

	using namespace luabind;

	luabind::open(L);

	module(L)[
		class_<VoxelRegistry, bases<>, sp_<VoxelRegistry>>("VoxelRegistry")
			//.def("create", &interface::createVoxelRegistry, adopt_policy<0>())
			.def("serialize", (ss_(VoxelRegistry::*)())
					&VoxelRegistry::serialize)
			.def("deserialize", (void(VoxelRegistry::*)(const ss_&))
					&VoxelRegistry::deserialize),
		def("createVoxelRegistry", &interface::createVoxelRegistry,
				adopt_policy<0>())
	];
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
