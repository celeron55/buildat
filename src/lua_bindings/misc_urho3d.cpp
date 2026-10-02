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
#include <Image.h>
#include <Profiler.h>
#include <ResourceCache.h>
#include <Camera.h>
#include <Graphics.h>
#include <Node.h>
#include <Renderer.h>
#include <RenderSurface.h>
#include <Texture2D.h>
#include <Viewport.h>
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

// profiler_data(max_depth) -> string: Urho3D's profiler table for the
// interval since the last call (a block's average and max per frame), which
// is what says where a frame went when the script's own marks do not
// ([FRAME_PEAK]). Each call starts the next interval.
static int l_profiler_data(lua_State *L)
{
	int max_depth = luaL_optinteger(L, 1, 3);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	Profiler *profiler = context->GetSubsystem<magic::Profiler>();
	if(!profiler)
		return 0;
	magic::String data = profiler->PrintData(false, false, max_depth);
	profiler->BeginInterval();
	lua_pushstring(L, data.CString());
	return 1;
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
	if(!interface::fs::is_inside_path(path,
			g_client_config.get<ss_>("cache_path")))
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

// render_scene_to_texture(scene: Scene, camera_node: Node, w, h) -> Texture2D
//
// A scene drawn into a texture instead of into the window. What wants it is a
// thumbnail: a model or a voxel volume seen on its own, on a button.
//
// One function rather than RenderSurface, its update modes and the texture
// formats, because a thumbnail is all anyone has needed; exposing the surface
// properly is what a live mirror or a portal would want.
//
// simplified: the surface updates every frame for as long as the texture
// lives, and neither is ever freed. A thumbnail's scene is a few thousand
// voxels at 96x96, so this is cheap, and it is what makes a texture correct
// after geometry that was built asynchronously arrives. The upgrade path is
// a manual update mode and a call to queue one.
static int l_render_scene_to_texture(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(scene, 1, Scene);
	GET_TOLUA_STUFF(camera_node, 2, Node);
	int w = lua_tointeger(L, 3);
	int h = lua_tointeger(L, 4);
	if(w <= 0 || h <= 0 || w > 4096 || h > 4096)
		return luaL_error(L, "render_scene_to_texture(): %ix%i is not a "
				"sensible size", w, h);
	Camera *camera = camera_node->GetComponent<Camera>();
	if(camera == nullptr)
		return luaL_error(L, "render_scene_to_texture(): the node has no "
				"Camera component");

	Context *context = scene->GetContext();
	SharedPtr<Texture2D> texture(new Texture2D(context));
	texture->SetSize(w, h, Graphics::GetRGBFormat(), TEXTURE_RENDERTARGET);
	texture->SetFilterMode(FILTER_BILINEAR);
	RenderSurface *surface = texture->GetRenderSurface();
	if(surface == nullptr)
		return luaL_error(L, "render_scene_to_texture(): the texture has no "
				"render surface");
	surface->SetViewport(0, new Viewport(context, scene, camera));
	surface->SetUpdateMode(SURFACE_UPDATEALWAYS);

	// Held by a reference that is never released, because what goes to Lua is
	// a raw pointer and nothing else holds one. Deliberately leaked rather
	// than kept in a container: a container of SharedPtr destroyed at exit
	// tears a viewport down after Urho3D's context is gone, which is a crash
	// on the way out.
	texture->AddRef();

	tolua_pushusertype(L, (void*)texture.Get(), "Texture2D");
	return 1;
}

// set_preferred_viewports({viewport, ...}). An empty table is teardown.
// The engine draws these at the user's render_scale; see
// CApp::apply_preferred_viewports() in src/client/app.cpp.
static int l_set_preferred_viewports(lua_State *L)
{
	tolua_Error tolua_err;
	if(!lua_istable(L, 1))
		return luaL_error(L, "set_preferred_viewports(): expected a table");

	sv_<Viewport*> viewports;
	size_t n = lua_objlen(L, 1);
	for(size_t i = 1; i <= n; i++){
		lua_rawgeti(L, 1, i);
		GET_TOLUA_STUFF(viewport, -1, Viewport);
		lua_pop(L, 1);
		viewports.push_back(viewport);
	}

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	buildat_app->set_preferred_viewports(viewports);
	return 0;
}

// set_voxel_data(node, data: string)
// A chunk node's buildat_voxel_data from a string, which is what a volume
// serializes to; the mesher reads the var and a string has no way into a
// Variant from the sandbox. For a client's predicted dig or place
// ([PREDICTION]); the server's replication of the var overwrites it.
static int l_set_voxel_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(node, 1, Node);
	size_t len = 0;
	const char *data = lua_tolstring(L, 2, &len);
	if(!data)
		throw Exception("set_voxel_data: data must be a string");
	node->SetVar(StringHash("buildat_voxel_data"), Variant(
			PODVector<uint8_t>((const uint8_t*)data, len)));
	return 0;
}

// image_set_data(image, w, h, components, data: string)
// **A generated tile in one call** ([ROOM_BOOT], 2026-09-24): the room
// draws seventy marks at boot and each was four thousand wrapped
// SetPixel calls -- a quarter of a million crossings of the sandbox for
// pictures that are built in Lua and never read back. Image::SetData
// takes the whole buffer, and a Lua string is already one; it is not in
// Urho3D's own .pkg, so it is bound here rather than regenerated there.
// components is 1 to 4: luminance, luminance and alpha, rgb, rgba.
static int l_image_set_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(image, 1, Image);
	int w = lua_tointeger(L, 2);
	int h = lua_tointeger(L, 3);
	int comps = lua_tointeger(L, 4);
	size_t len = 0;
	const char *data = lua_tolstring(L, 5, &len);
	if(!data)
		throw Exception("image_set_data: data must be a string");
	if(w < 1 || h < 1 || comps < 1 || comps > 4)
		throw Exception("image_set_data: w, h >= 1 and components 1..4");
	if(len != (size_t)w * (size_t)h * (size_t)comps)
		throw Exception("image_set_data: the string is not w * h * "
				"components bytes");
	if(!image->SetSize(w, h, comps))
		throw Exception("image_set_data: SetSize failed");
	image->SetData((const unsigned char*)data);
	return 0;
}

// get_voxel_data(node) -> string, or nil for a node without the var
static int l_get_voxel_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(node, 1, Node);
	const Variant &var = node->GetVar(StringHash("buildat_voxel_data"));
	if(var.GetType() != VAR_BUFFER){
		lua_pushnil(L);
		return 1;
	}
	const PODVector<uint8_t> &buf = var.GetBuffer();
	lua_pushlstring(L, buf.Size() ? (const char*)&buf[0] : "", buf.Size());
	return 1;
}

void init_misc_urho3d(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(profiler_block_begin);
	DEF_BUILDAT_FUNC(profiler_block_end);
	DEF_BUILDAT_FUNC(profiler_data);
	DEF_BUILDAT_FUNC(add_resource_dir);
	DEF_BUILDAT_FUNC(render_scene_to_texture);
	DEF_BUILDAT_FUNC(set_preferred_viewports);
	DEF_BUILDAT_FUNC(set_voxel_data);
	DEF_BUILDAT_FUNC(get_voxel_data);
	DEF_BUILDAT_FUNC(image_set_data);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
