// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include <tolua++.h>
#include <Vector3.h>
#include <cassert>
#include <map>
#include <unordered_map>
#define MODULE "lua_bindings"

#define DEF_METHOD(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setfield(L, -2, #name); \
}

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

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace lua_bindings {

struct SpatialUpdateQueue
{
	struct Value {
		ss_ type;
		uint32_t node_id = -1;

		bool operator==(const Value &other) const {
			return node_id == other.node_id && type == other.type;
		}
	};

	struct ValueHash {
		size_t operator()(const Value &v) const {
			return std::hash<ss_>()(v.type) ^
					(std::hash<uint32_t>()(v.node_id) * 2654435761u);
		}
	};

	struct Item { // Queue item
		Vector3 p = Vector3(0, 0, 0);
		Value value;
		float near_weight = -1.0f;
		float near_trigger_d = -1.0f;
		float far_weight = -1.0f;
		float far_trigger_d = -1.0f;
		float f = -1.0f;
		float fw = -1.0f;
	};

	// Items that are due (f <= 1) come before ones that are not, and among
	// those the smallest fw is the most important. That is the order the queue
	// is popped in, so it is the order the map keeps.
	typedef std::pair<bool, float> Key; // (f > 1.0f, fw)
	typedef std::multimap<Key, Item> Queue;

	Vector3 m_p;
	Vector3 m_queue_oldest_p;
	Queue m_queue;
	// Iterators into m_queue by value, so that an item can be found and
	// replaced without walking the queue
	std::unordered_map<Value, Queue::iterator, ValueHash> m_index;
	// Items waiting to be re-put with a new f; a plain stack, because they are
	// all going to be re-sorted anyway
	sv_<Item> m_old_queue;

	static Key key_of(const Item &item)
	{
		return Key(item.f > 1.0f, item.fw);
	}

	void update(int max_operations)
	{
		if(m_old_queue.empty())
			return;
		log_d(MODULE, "SpatialUpdateQueue(): Items in old queue: %zu",
				m_old_queue.size());
		for(int i = 0; i<max_operations; i++){
			if(m_old_queue.empty())
				break;
			Item item = m_old_queue.back();
			m_old_queue.pop_back();
			put_item(item);
		}
	}

	void set_p(const Vector3 &p)
	{
		m_p = p;
		if(m_old_queue.empty() && (m_p - m_queue_oldest_p).Length() > 20){
			m_old_queue.reserve(m_queue.size());
			for(auto &pair : m_queue)
				m_old_queue.push_back(pair.second);
			m_queue.clear();
			m_index.clear();
			m_queue_oldest_p = m_p;
		}
	}

	void put_item(Item &item)
	{
		if(item.near_trigger_d == -1.0f && item.far_trigger_d == -1.0f)
			throw Exception("Item has neither trigger");
		float d = (item.p - m_p).Length();
		item.f = -1.0f;
		item.fw = -1.0f;
		if(item.near_trigger_d != -1.0f){
			float f_near = d / item.near_trigger_d;
			float fw_near = f_near / item.near_weight;
			if(item.fw == -1.0f || (fw_near < item.fw &&
					(item.f == -1.0f || f_near < item.f))){
				item.f = f_near;
				item.fw = fw_near;
			}
		}
		if(item.far_trigger_d != -1.0f){
			float f_far = item.far_trigger_d / d;
			float fw_far = f_far / item.far_weight;
			if(item.fw == -1.0f || (fw_far < item.fw &&
					(item.f == -1.0f || f_far < item.f))){
				item.f = f_far;
				item.fw = fw_far;
			}
		}
		if(item.f == -1.0f || item.fw == -1.0f)
			throw Exception("item.f == -1.0f || item.fw == -1.0f");

		// Find old entry; if the old entry is more important, discard the new
		// one; if the old entry is less important, remove the old entry
		auto index_it = m_index.find(item.value);
		if(index_it != m_index.end()){
			if(index_it->second->second.fw < item.fw){
				// Old item is more important
				return;
			}
			// New item is more important
			m_queue.erase(index_it->second);
			m_index.erase(index_it);
		}

		m_index[item.value] = m_queue.insert(
				std::make_pair(key_of(item), item));
	}

	void put(const Vector3 &p, float near_weight, float near_trigger_d,
			float far_weight, float far_trigger_d, const Value &value)
	{
		Item item;
		item.p = p;
		item.near_weight = near_weight;
		item.near_trigger_d = near_trigger_d;
		item.far_weight = far_weight;
		item.far_trigger_d = far_trigger_d;
		item.value = value;
		put_item(item);
	}

	bool empty()
	{
		return m_queue.empty();
	}

	void pop()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::pop(): Empty");
		auto it = m_queue.begin();
		m_index.erase(it->second.value);
		m_queue.erase(it);
	}

	Value& get_value()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::get_value(): Empty");
		return m_queue.begin()->second.value;
	}

	float get_f()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::get_f(): Empty");
		return m_queue.begin()->second.f;
	}

	float get_fw()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::get_fw(): Empty");
		return m_queue.begin()->second.fw;
	}

	size_t get_length()
	{
		return m_queue.size();
	}
};

// The queue decides the order chunks are meshed in, and a silent ordering or
// replacement bug there shows up only as chunks meshing late. Runs at startup;
// it is a few microseconds.
static void self_check()
{
	auto item_value = [](const char *type, uint32_t node_id){
		SpatialUpdateQueue::Value v;
		v.type = type;
		v.node_id = node_id;
		return v;
	};

	// Whichever is closest to its near trigger comes first, and f > 1 (not due
	// yet) goes behind f <= 1 whatever the weights say
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(50, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // f = 0.5
		q.put(Vector3(10, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2)); // f = 0.1
		q.put(Vector3(200, 0, 0), 0.01f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 3)); // f = 2, lowest fw of the three
		assert(q.get_length() == 3);
		assert(q.get_value().node_id == 2);
		q.pop();
		assert(q.get_value().node_id == 1);
		q.pop();
		assert(q.get_value().node_id == 3);
		q.pop();
		assert(q.empty());
	}

	// The same value put twice is one item: the more important put wins,
	// whichever order the two come in
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(50, 0, 0), 0.1f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // fw = 5
		q.put(Vector3(50, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // fw = 0.5, more important
		assert(q.get_length() == 1);
		assert(q.get_fw() < 1.0f);
		q.put(Vector3(50, 0, 0), 0.1f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // less important, discarded
		assert(q.get_length() == 1);
		assert(q.get_fw() < 1.0f);
		// Same node, other type, is a different value
		q.put(Vector3(50, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("physics", 1));
		assert(q.get_length() == 2);
	}

	// Moving far enough re-puts everything against the new position
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(0, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1));
		q.put(Vector3(500, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2));
		q.set_p(Vector3(500, 0, 0));
		assert(q.empty()); // Everything is waiting to be re-put
		q.update(10);
		assert(q.get_length() == 2);
		assert(q.get_value().node_id == 2); // Now the near one
	}
}

struct LuaSUQ
{
	static constexpr const char *class_name = "SpatialUpdateQueue";
	SpatialUpdateQueue internal;

	static int gc_object(lua_State *L){
		delete *(LuaSUQ**)(lua_touserdata(L, 1));
		return 0;
	}
	static int l_update(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		int max_operations = luaL_checkinteger(L, 2);
		o->internal.update(max_operations);
		return 0;
	}
	static int l_set_p(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		tolua_Error tolua_err;
		GET_TOLUA_STUFF(p, 2, Vector3);
		o->internal.set_p(*p);
		return 0;
	}
	static int l_put(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		tolua_Error tolua_err;
		GET_TOLUA_STUFF(p, 2, Vector3);
		float near_weight = (lua_type(L, 3) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 3);
		float near_trigger_d = (lua_type(L, 4) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 4);
		float far_weight = (lua_type(L, 5) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 5);
		float far_trigger_d = (lua_type(L, 6) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		SpatialUpdateQueue::Value value;
		lua_getfield(L, -1, "type");
		value.type = luaL_checkstring(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, -1, "node_id");
		value.node_id = luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		o->internal.put(*p, near_weight, near_trigger_d,
				far_weight, far_trigger_d, value);
		return 0;
	}
	static int l_get(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		SpatialUpdateQueue::Value &value = o->internal.get_value();
		lua_newtable(L);
		lua_pushstring(L, value.type.c_str());
		lua_setfield(L, -2, "type");
		lua_pushinteger(L, value.node_id);
		lua_setfield(L, -2, "node_id");
		o->internal.pop();
		return 1;
	}
	static int l_peek_next_f(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		float v = o->internal.get_f();
		lua_pushnumber(L, v);
		return 1;
	}
	static int l_peek_next_fw(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		float v = o->internal.get_fw();
		lua_pushnumber(L, v);
		return 1;
	}
	static int l_get_length(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		int l = o->internal.get_length();
		lua_pushinteger(L, l);
		return 1;
	}

	static LuaSUQ* internal_checkobject(lua_State *L, int narg){
		luaL_checktype(L, narg, LUA_TUSERDATA);
		void *ud = luaL_checkudata(L, narg, class_name);
		if(!ud) luaL_typerror(L, narg, class_name);
		return *(LuaSUQ**)ud;
	}
	static int l_create(lua_State *L){
		LuaSUQ *o = new LuaSUQ();
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
		DEF_METHOD(update);
		DEF_METHOD(set_p);
		DEF_METHOD(put);
		DEF_METHOD(get);
		DEF_METHOD(peek_next_f);
		DEF_METHOD(peek_next_fw);
		DEF_METHOD(get_length);

		// drop method_table_L
		lua_pop(L, 1);
	}
};

static int l_SpatialUpdateQueue(lua_State *L)
{
	return LuaSUQ::l_create(L);
}

void init_spatial_update_queue(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}
	self_check();

	LuaSUQ::register_metatable(L);

	DEF_BUILDAT_FUNC(SpatialUpdateQueue);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
