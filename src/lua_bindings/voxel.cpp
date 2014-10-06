// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include "interface/mesh.h"
#include <tolua++.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Scene.h>
#include <StaticModel.h>
#include <Model.h>
#pragma GCC diagnostic pop
#define MODULE "lua_bindings"

namespace magic = Urho3D;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace lua_bindings {

// NOTE: This API is designed this way because otherwise ownership management of
//       objects sucks
// set_simple_voxel_model(node, w, h, d, data: string)
static int l_set_simple_voxel_model(lua_State *L)
{
	int w = lua_tointeger(L, 2);
	int h = lua_tointeger(L, 3);
	int d = lua_tointeger(L, 4);
	ss_ data = lua_tocppstring(L, 5);

	if((int)data.size() != w * h * d){
		log_e(MODULE, "set_simple_voxel_model(): Data size does not match "
				"with dimensions (%zu vs. %i)", data.size(), w*h*d);
		return 0;
	}

	tolua_Error tolua_err;
	//if(!tolua_isusertype(L, 1, "const Node", 0, &tolua_err)){
	if(!tolua_isusertype(L, 1, "Node", 0, &tolua_err)){
		tolua_error(L, "Error in set_simple_voxel_model", &tolua_err);
		return 0;
	}
	log_d(MODULE, "set_simple_voxel_model(): Valid Node given");
	//const Node *node = (const Node*)tolua_tousertype(L, 1, 0);
	Node *node = (Node*)tolua_tousertype(L, 1, 0);
	log_d(MODULE, "set_simple_voxel_model(): node=%p", node);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	SharedPtr<Model> fromScratchModel(
			interface::create_simple_voxel_model(context, w, h, d, data));

	StaticModel* object = node->CreateComponent<StaticModel>();
	object->SetModel(fromScratchModel);

	return 0;
}

void init_voxel(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){\
	lua_pushcfunction(L, l_##name);\
	lua_setglobal(L, "__buildat_" #name);\
}
	DEF_BUILDAT_FUNC(set_simple_voxel_model);
}

} // namespace lua_bindingss
// vim: set noet ts=4 sw=4:

