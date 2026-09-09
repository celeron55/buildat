// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Raster operations over an RGBA canvas: load an image by resource name, blit
// it, blend a colour into it, shift its hue, turn it, crop it, scale it, and
// write what comes out as a PNG.
//
// What wanted this is Luanti's texture modifiers -- "dirt.png^grass.png",
// "[colorize:#ff0000:128", "[combine:32x32:0,0=a.png:16,0=b.png" -- which are
// a small language over exactly these operations. The language is not here:
// parsing it is a page of Lua, and what is worth having in the engine is the
// pixels. Nothing in this file knows what a node or a modifier is.
//
// A composition writes one file, and a nested expression is one composition
// per level with the inner results referenced by name, which is why there is
// no way to hold an intermediate image: the file is the intermediate, and it
// doubles as a cache between runs.
#include "lua_bindings/util.h"
#include "lua_bindings/luabind_util.h"
#include "core/log.h"
#include "client/app.h"
#include "client/config.h"
#include "interface/fs.h"
#include <luabind/luabind.hpp>
#include <luabind/object.hpp>
#include <luabind/iterator_policy.hpp>
#include <Context.h>
#include <Image.h>
#include <ResourceCache.h>
#include <Scene.h>
#include <Color.h>
#include <cmath>
#include <algorithm>
#define MODULE "lua_bindings"

namespace magic = Urho3D;

extern client::Config g_client_config;

namespace lua_bindings {

// A canvas is 4 bytes per pixel, r g b a, top row first. Nothing bigger than
// this is a texture; the limit is here so that a broken size cannot ask for an
// arbitrary allocation.
static const int IMAGE_MAX_SIZE = 4096;

struct Canvas
{
	int w = 0;
	int h = 0;
	sv_<uint8_t> data;

	void reset(int w_, int h_)
	{
		if(w_ <= 0 || h_ <= 0 || w_ > IMAGE_MAX_SIZE || h_ > IMAGE_MAX_SIZE)
			throw Exception(ss_()+"compose_image(): bad image size "+
					itos(w_)+"x"+itos(h_));
		w = w_;
		h = h_;
		data.assign((size_t)w * h * 4, 0);
	}

	uint8_t* at(int x, int y){ return &data[((size_t)y * w + x) * 4]; }
};

static double table_number(const luabind::object &t, const char *key,
		double default_value)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static double table_number_at(const luabind::object &t, int index,
		double default_value)
{
	luabind::object v = t[index];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static ss_ table_string(const luabind::object &t, const char *key)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TSTRING)
		return "";
	return luabind::object_cast<ss_>(v);
}

// An array of numbers, as the caller writes a position, a size, a rectangle or
// a colour. Returns how many entries were there.
static int table_ints(const luabind::object &t, const char *key, int *result,
		int count)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TTABLE)
		return 0;
	int got = 0;
	for(int i = 0; i < count; i++){
		luabind::object e = v[i + 1];
		if(!e || luabind::type(e) != LUA_TNUMBER)
			break;
		result[i] = (int)luabind::object_cast<double>(e);
		got++;
	}
	return got;
}

static uint8_t clamp_byte(int v)
{
	return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// One source image, as RGBA. Urho3D's images come in whatever the file had, so
// they are read through GetPixel() rather than out of the buffer.
static void load_source(magic::Context *context, const ss_ &name,
		Canvas &dst)
{
	auto *cache = context->GetSubsystem<magic::ResourceCache>();
	magic::Image *img = cache->GetResource<magic::Image>(name.c_str());
	if(img == nullptr)
		throw Exception("compose_image(): could not load \""+name+"\"");
	dst.reset(img->GetWidth(), img->GetHeight());
	for(int y = 0; y < dst.h; y++){
		for(int x = 0; x < dst.w; x++){
			magic::Color c = img->GetPixel(x, y);
			uint8_t *p = dst.at(x, y);
			p[0] = clamp_byte((int)(c.r_ * 255.0f + 0.5f));
			p[1] = clamp_byte((int)(c.g_ * 255.0f + 0.5f));
			p[2] = clamp_byte((int)(c.b_ * 255.0f + 0.5f));
			p[3] = clamp_byte((int)(c.a_ * 255.0f + 0.5f));
		}
	}
}

enum BlendMode {
	BLEND_OVER,     // Alpha compositing, which is what an overlay is
	BLEND_SET,      // Replace, alpha included
	BLEND_AND,      // Bitwise, per channel; this is what a mask is
	BLEND_MULTIPLY,
	BLEND_SCREEN,
};

static BlendMode parse_blend(const ss_ &s)
{
	if(s == "" || s == "over")
		return BLEND_OVER;
	if(s == "set")
		return BLEND_SET;
	if(s == "and")
		return BLEND_AND;
	if(s == "multiply")
		return BLEND_MULTIPLY;
	if(s == "screen")
		return BLEND_SCREEN;
	throw Exception("compose_image(): unknown blend \""+s+"\"");
}

static void blend_pixel(const uint8_t *src, uint8_t *dst, BlendMode mode)
{
	switch(mode){
	case BLEND_SET:
		for(int i = 0; i < 4; i++)
			dst[i] = src[i];
		return;
	case BLEND_AND:
		for(int i = 0; i < 4; i++)
			dst[i] = src[i] & dst[i];
		return;
	case BLEND_MULTIPLY:
		for(int i = 0; i < 3; i++)
			dst[i] = (uint8_t)(dst[i] * src[i] / 255);
		return;
	case BLEND_SCREEN:
		for(int i = 0; i < 3; i++)
			dst[i] = (uint8_t)(255 - (255 - dst[i]) * (255 - src[i]) / 255);
		return;
	case BLEND_OVER:
		break;
	}
	// Alpha compositing, gamma-incorrect, which is what every 2D blit of this
	// kind does and what the textures were painted against
	uint8_t sa = src[3];
	if(sa == 0)
		return;
	if(sa == 255 || dst[3] == 0){
		for(int i = 0; i < 4; i++)
			dst[i] = src[i];
		return;
	}
	int out_a = sa + dst[3] * (255 - sa) / 255;
	for(int i = 0; i < 3; i++){
		int s = src[i] * sa;
		int d = dst[i] * dst[3] * (255 - sa) / 255;
		dst[i] = clamp_byte(out_a > 0 ? (s + d) / out_a : 0);
	}
	dst[3] = clamp_byte(out_a);
}

// dst[x0..x0+w, y0..y0+h] gets src's from-rectangle, scaled by nearest
// neighbour, which is what pixel art wants. Anything outside dst is clipped.
static void blit(Canvas &dst, const Canvas &src, int from[4], int at[2],
		int size[2], BlendMode mode)
{
	if(size[0] <= 0 || size[1] <= 0 || from[2] <= 0 || from[3] <= 0)
		return;
	for(int dy = 0; dy < size[1]; dy++){
		int y = at[1] + dy;
		if(y < 0 || y >= dst.h)
			continue;
		int sy = from[1] + (int)((int64_t)dy * from[3] / size[1]);
		if(sy < 0 || sy >= src.h)
			continue;
		for(int dx = 0; dx < size[0]; dx++){
			int x = at[0] + dx;
			if(x < 0 || x >= dst.w)
				continue;
			int sx = from[0] + (int)((int64_t)dx * from[2] / size[0]);
			if(sx < 0 || sx >= src.w)
				continue;
			blend_pixel(&src.data[((size_t)sy * src.w + sx) * 4],
					dst.at(x, y), mode);
		}
	}
}

// The source mapped onto a parallelogram: its own four corners go to at,
// at+u, at+u+v and at+v. This is the one thing a rectangular blit cannot do
// and the little cube an inventory draws a voxel as needs -- three faces,
// three parallelograms.
//
// Worked backwards, from each destination pixel to the source pixel it came
// from, so that the result has no gaps whatever the edges are: the matrix of
// the two edge vectors is inverted and every pixel of the parallelogram's
// bounding box is asked which source pixel it holds. Pixel centres decide it,
// so two parallelograms sharing an edge claim the pixels along it once each.
static void shear(Canvas &dst, const Canvas &src, const int at[2],
		const int u[2], const int v[2], BlendMode mode)
{
	double det = (double)u[0] * v[1] - (double)u[1] * v[0];
	if(std::fabs(det) < 1e-9)
		return; // A parallelogram with no area covers nothing
	double xs[4] = {(double)at[0], (double)(at[0] + u[0]),
			(double)(at[0] + v[0]), (double)(at[0] + u[0] + v[0])};
	double ys[4] = {(double)at[1], (double)(at[1] + u[1]),
			(double)(at[1] + v[1]), (double)(at[1] + u[1] + v[1])};
	int x0 = std::max(0, (int)std::floor(*std::min_element(xs, xs + 4)));
	int x1 = std::min(dst.w, (int)std::ceil(*std::max_element(xs, xs + 4)));
	int y0 = std::max(0, (int)std::floor(*std::min_element(ys, ys + 4)));
	int y1 = std::min(dst.h, (int)std::ceil(*std::max_element(ys, ys + 4)));
	for(int y = y0; y < y1; y++){
		for(int x = x0; x < x1; x++){
			double px = x + 0.5 - at[0];
			double py = y + 0.5 - at[1];
			// (a, b) such that the pixel is at a*u + b*v from at
			double a = (v[1] * px - v[0] * py) / det;
			double b = (u[0] * py - u[1] * px) / det;
			if(a < 0.0 || a >= 1.0 || b < 0.0 || b >= 1.0)
				continue;
			int sx = (int)(a * src.w);
			int sy = (int)(b * src.h);
			if(sx < 0 || sx >= src.w || sy < 0 || sy >= src.h)
				continue;
			blend_pixel(&src.data[((size_t)sy * src.w + sx) * 4],
					dst.at(x, y), mode);
		}
	}
}

// The eight symmetries of a square, in Luanti's order: 0 identity, 1..3
// rotations by 90 degrees counterclockwise, 4 flip x, 5..7 that flip followed
// by the rotations. An odd transform swaps the two dimensions.
static void transform_canvas(Canvas &c, int transform)
{
	if(transform < 0 || transform > 7)
		throw Exception(ss_()+"compose_image(): transform "+itos(transform)+
				" is not one of the eight");
	if(transform == 0)
		return;
	Canvas out;
	out.reset((transform % 2) ? c.h : c.w, (transform % 2) ? c.w : c.h);
	static const int SXN[8] = {0, 3, 1, 2, 1, 2, 0, 3};
	static const int SYN[8] = {2, 0, 3, 1, 2, 0, 3, 1};
	for(int dy = 0; dy < out.h; dy++){
		for(int dx = 0; dx < out.w; dx++){
			int entries[4] = {dx, out.w - 1 - dx, dy, out.h - 1 - dy};
			int sx = entries[SXN[transform]];
			int sy = entries[SYN[transform]];
			if(sx < 0 || sx >= c.w || sy < 0 || sy >= c.h)
				continue;
			memcpy(out.at(dx, dy), c.at(sx, sy), 4);
		}
	}
	c.w = out.w;
	c.h = out.h;
	c.data.swap(out.data);
}

// Blends every pixel towards a colour. ratio is 0...255; a fully transparent
// pixel is left alone, because its rgb is not a colour anybody chose.
static void colorize(Canvas &c, const int color[4], int ratio)
{
	for(size_t i = 0; i < c.data.size(); i += 4){
		uint8_t *p = &c.data[i];
		if(p[3] == 0)
			continue;
		if(ratio >= 255){
			for(int k = 0; k < 3; k++)
				p[k] = clamp_byte(color[k]);
			p[3] = clamp_byte(p[3] * clamp_byte(color[3]) / 255);
			continue;
		}
		for(int k = 0; k < 3; k++)
			p[k] = clamp_byte((color[k] * ratio + p[k] * (255 - ratio)) / 255);
	}
}

// Hue in degrees, saturation and lightness as percentages of the way towards
// full or empty, which is how an image editor's hue-saturation tool reads.
static void hue_saturation(Canvas &c, double hue, double saturation,
		double lightness)
{
	double norm_s = saturation / 100.0;
	double norm_l = lightness / 100.0;
	for(size_t i = 0; i < c.data.size(); i += 4){
		uint8_t *p = &c.data[i];
		magic::Color in(p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f);
		float h = in.Hue();
		float s = in.SaturationHSL();
		float l = in.Lightness();
		if(norm_l < 0)
			l *= (float)(norm_l + 1.0);
		else
			l = (float)(l + norm_l * (1.0 - l));
		s = (float)(s * (norm_s + 1.0));
		if(s < 0.0f)
			s = 0.0f;
		if(s > 1.0f)
			s = 1.0f;
		h = (float)fmod(h + hue / 360.0, 1.0);
		if(h < 0.0f)
			h += 1.0f;
		magic::Color out;
		out.FromHSL(h, s, l, 1.0f);
		p[0] = clamp_byte((int)(out.r_ * 255.0f + 0.5f));
		p[1] = clamp_byte((int)(out.g_ * 255.0f + 0.5f));
		p[2] = clamp_byte((int)(out.b_ * 255.0f + 0.5f));
	}
}

static void apply_op(magic::Context *context, Canvas &c,
		const luabind::object &t, bool &have_canvas)
{
	if(luabind::type(t) != LUA_TTABLE)
		throw Exception("compose_image(): an op is not a table");
	ss_ op = table_string(t, "op");

	if(op == "blit"){
		ss_ src_name = table_string(t, "src");
		if(src_name == "")
			throw Exception("compose_image(): blit has no src");
		Canvas src;
		load_source(context, src_name, src);
		int from[4] = {0, 0, src.w, src.h};
		table_ints(t, "from", from, 4);
		int at[2] = {0, 0};
		table_ints(t, "at", at, 2);
		int size[2] = {from[2], from[3]};
		table_ints(t, "size", size, 2);
		// The first blit of a composition that was given no size decides it,
		// which is what makes a chain of overlays take the base image's size
		if(!have_canvas){
			c.reset(at[0] + size[0], at[1] + size[1]);
			have_canvas = true;
		}
		// fill stretches the source over the whole canvas, which is what an
		// overlay of a different size wants
		luabind::object fill_o = t["fill"];
		if(fill_o && luabind::object_cast<bool>(fill_o)){
			at[0] = 0;
			at[1] = 0;
			size[0] = c.w;
			size[1] = c.h;
		}
		blit(c, src, from, at, size, parse_blend(table_string(t, "blend")));
		return;
	}

	if(op == "fill"){
		int color[4] = {0, 0, 0, 255};
		table_ints(t, "color", color, 4);
		if(!have_canvas)
			throw Exception("compose_image(): fill before there is a canvas");
		int at[2] = {0, 0};
		table_ints(t, "at", at, 2);
		int size[2] = {c.w, c.h};
		table_ints(t, "size", size, 2);
		BlendMode mode = parse_blend(table_string(t, "blend"));
		uint8_t px[4] = {clamp_byte(color[0]), clamp_byte(color[1]),
				clamp_byte(color[2]), clamp_byte(color[3])};
		for(int y = at[1]; y < at[1] + size[1]; y++){
			if(y < 0 || y >= c.h)
				continue;
			for(int x = at[0]; x < at[0] + size[0]; x++){
				if(x < 0 || x >= c.w)
					continue;
				blend_pixel(px, c.at(x, y), mode);
			}
		}
		return;
	}

	if(!have_canvas)
		throw Exception("compose_image(): \""+op+
				"\" before there is a canvas");

	if(op == "shear"){
		ss_ src_name = table_string(t, "src");
		if(src_name == "")
			throw Exception("compose_image(): shear has no src");
		Canvas src;
		load_source(context, src_name, src);
		int at[2] = {0, 0};
		table_ints(t, "at", at, 2);
		int u[2] = {src.w, 0};
		int v[2] = {0, src.h};
		table_ints(t, "u", u, 2);
		table_ints(t, "v", v, 2);
		shear(c, src, at, u, v, parse_blend(table_string(t, "blend")));
		return;
	}

	if(op == "multiply"){
		int color[4] = {255, 255, 255, 255};
		table_ints(t, "color", color, 4);
		for(size_t i = 0; i < c.data.size(); i += 4){
			for(int k = 0; k < 4; k++)
				c.data[i + k] = (uint8_t)(c.data[i + k] *
						clamp_byte(color[k]) / 255);
		}
		return;
	}
	if(op == "colorize"){
		int color[4] = {255, 255, 255, 255};
		table_ints(t, "color", color, 4);
		colorize(c, color, (int)table_number(t, "ratio", 255));
		return;
	}
	if(op == "hsl"){
		hue_saturation(c, table_number(t, "hue", 0),
				table_number(t, "saturation", 0),
				table_number(t, "lightness", 0));
		return;
	}
	if(op == "alpha"){
		uint8_t a = clamp_byte((int)table_number(t, "value", 255));
		for(size_t i = 3; i < c.data.size(); i += 4)
			c.data[i] = a;
		return;
	}
	if(op == "transform"){
		transform_canvas(c, (int)table_number(t, "transform", 0));
		return;
	}
	if(op == "resize" || op == "crop"){
		int from[4] = {0, 0, c.w, c.h};
		if(op == "crop"){
			// Either a rectangle, or one cell of a grid the canvas is cut
			// into, which is what a sprite sheet or a stack of animation
			// frames is
			int grid[2] = {1, 1};
			if(table_ints(t, "grid", grid, 2) == 2){
				// A zero says to work that side out so that the cells come
				// out square, which is what a strip of animation frames is:
				// as many frames as its height holds of its width.
				if(grid[0] == 0 && grid[1] > 0)
					grid[0] = std::max(1, c.w / std::max(1, c.h / grid[1]));
				if(grid[1] == 0 && grid[0] > 0)
					grid[1] = std::max(1, c.h / std::max(1, c.w / grid[0]));
				if(grid[0] < 1 || grid[1] < 1)
					throw Exception("compose_image(): crop grid is empty");
				int cell[2] = {0, 0};
				table_ints(t, "cell", cell, 2);
				from[2] = c.w / grid[0] > 0 ? c.w / grid[0] : 1;
				from[3] = c.h / grid[1] > 0 ? c.h / grid[1] : 1;
				from[0] = cell[0] * from[2];
				from[1] = cell[1] * from[3];
			} else {
				table_ints(t, "from", from, 4);
			}
		}
		int size[2] = {from[2], from[3]};
		table_ints(t, "size", size, 2);
		Canvas out;
		out.reset(size[0], size[1]);
		int at[2] = {0, 0};
		blit(out, c, from, at, size, BLEND_SET);
		c.w = out.w;
		c.h = out.h;
		c.data.swap(out.data);
		return;
	}
	throw Exception("compose_image(): unknown op \""+op+"\"");
}

// compose_image(args) -> width, height
//
// args.size is the canvas, args.ops the operations over it and args.write the
// path the result is saved to. See doc/client_api.txt.
static int l_compose_image(lua_State *L)
{
	try {
		luabind::object args(luabind::from_stack(L, 1));
		if(!args || luabind::type(args) != LUA_TTABLE)
			throw Exception("compose_image(): args is not a table");

		// A written file has to end up somewhere the client owns; the caller
		// puts it where its resource dirs are, which is under the cache
		ss_ write = table_string(args, "write");
		if(write == "")
			throw Exception("compose_image(): args.write is missing");
		ss_ path = interface::fs::get_absolute_path(write);
		ss_ cache_path = interface::fs::get_absolute_path(
				g_client_config.get<ss_>("cache_path"));
		if(path.substr(0, cache_path.size()) != cache_path)
			throw Exception("compose_image(): \""+path+
					"\" is not under the cache path");

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::Context *context = buildat_app->get_scene()->GetContext();

		Canvas c;
		bool have_canvas = false;
		int size[2] = {0, 0};
		if(table_ints(args, "size", size, 2) == 2){
			c.reset(size[0], size[1]);
			have_canvas = true;
		}

		luabind::object ops = args["ops"];
		if(ops && luabind::type(ops) == LUA_TTABLE){
			for(luabind::iterator it(ops), end; it != end; ++it)
				apply_op(context, c, *it, have_canvas);
		}
		if(!have_canvas)
			throw Exception("compose_image(): nothing made a canvas");

		magic::SharedPtr<magic::Image> out(new magic::Image(context));
		out->SetSize(c.w, c.h, 4);
		out->SetData(&c.data[0]);
		if(!out->SavePNG(path.c_str()))
			throw Exception("compose_image(): could not write \""+path+"\"");

		lua_pushinteger(L, c.w);
		lua_pushinteger(L, c.h);
		return 2;
	} catch(std::exception &e){
		return luaL_error(L, "%s", e.what());
	}
}

// read_image(resource_name) -> width, height, rgba
//
// The pixels themselves, for whoever has to look at them rather than draw
// them. What wanted this is a colour palette: an image of a few dozen pixels
// that a game indexes to say what colour something is drawn in.
static int l_read_image(lua_State *L)
{
	try {
		ss_ name = luaL_checkstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::Context *context = buildat_app->get_scene()->GetContext();

		Canvas c;
		load_source(context, name, c);

		lua_pushinteger(L, c.w);
		lua_pushinteger(L, c.h);
		lua_pushlstring(L, (const char*)&c.data[0], c.data.size());
		return 3;
	} catch(std::exception &e){
		return luaL_error(L, "%s", e.what());
	}
}

void init_image(lua_State *L)
{
	lua_pushcfunction(L, l_compose_image);
	lua_setglobal(L, "__buildat_compose_image");
	lua_pushcfunction(L, l_read_image);
	lua_setglobal(L, "__buildat_read_image");
}

} // namespace lua_bindings
// vim: set noet ts=4 sw=4:
