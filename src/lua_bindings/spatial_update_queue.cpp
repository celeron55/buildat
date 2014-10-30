// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include <tolua++.h>
#include <Vector3.h>
#include <list>
#include <algorithm>
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

		bool operator>(const Item &other) const;
	};

	// Set of values with iterators for fast access of items, so that items
	// can be removed quickly by value
	struct ValueSet
	{
		struct Entry
		{
			Value value;
			std::list<Item>::iterator it;

			Entry(const Value &value, std::list<Item>::iterator it =
					std::list<Item>::iterator()):
				value(value), it(it)
			{}
			bool operator>(const Entry &other) const {
				if(value.node_id > other.value.node_id)
					return true;
				if(value.node_id < other.value.node_id)
					return false;
				return value.type > other.value.type;
			}
		};

		// sorted list in descending node_id and type order
		std::list<Entry> m_set;

		void clear(){
			m_set.clear();
		}
		void insert(const Value &value, std::list<Item>::iterator queue_it){
			Entry entry(value, queue_it);
			auto it = std::lower_bound(m_set.begin(), m_set.end(), entry,
						std::greater<Entry>());
			if(it == m_set.end())
				m_set.insert(it, entry);
			else if(it->value.node_id != value.node_id ||
					it->value.type != value.type)
				m_set.insert(it, entry);
			else
				*it = entry;
		}
		void remove(const Value &value){
			Entry entry(value);
			auto it = std::lower_bound(m_set.begin(), m_set.end(), entry,
						std::greater<Entry>());
			if(it == m_set.end())
				return;
			m_set.erase(it);
		}
		std::list<Item>::iterator*find(const Value &value){
			Entry entry(value);
			auto it = std::lower_bound(m_set.begin(), m_set.end(), entry,
						std::greater<Entry>());
			if(it == m_set.end())
				return nullptr;
			if(it->value.node_id != value.node_id ||
					it->value.type != value.type)
				return nullptr;
			return &(it->it);
		}
	};

	Vector3 m_p;
	Vector3 m_queue_oldest_p;
	size_t m_queue_length = 0; // GCC std::list's size() is O(n)
	std::list<Item> m_queue;
	std::list<Item> m_old_queue;

	ValueSet m_value_set;

	void update(int max_operations)
	{
		if(m_old_queue.empty())
			return;
		log_d(MODULE, "SpatialUpdateQueue(): Items in old queue: %zu",
				m_old_queue.size());
		for(int i = 0; i<max_operations; i++){
			if(m_old_queue.empty())
				break;
			Item &item = m_old_queue.back();
			put_item(item);
			m_old_queue.pop_back();
		}
	}

	void set_p(const Vector3 &p)
	{
		m_p = p;
		if(m_old_queue.empty() && (m_p - m_queue_oldest_p).Length() > 20){
			m_queue_length = 0;
			m_value_set.clear();
			m_old_queue.swap(m_queue);
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
		std::list<Item>::iterator *itp = m_value_set.find(item.value);
		if(itp != nullptr){
			Item &old_item = **itp;
			if(old_item.fw < item.fw){
				// Old item is more important
				return;
			} else {
				// New item is more important
				m_queue.erase(*itp);
				m_queue_length--;
				m_value_set.remove(item.value);
			}
		}

		auto it = std::lower_bound(m_queue.begin(), m_queue.end(),
					item, std::greater<Item>()); // position in descending order
		auto inserted_it = m_queue.insert(it, item);
		m_queue_length++;
		m_value_set.insert(item.value, inserted_it);
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
		Item &item = m_queue.back();
		m_value_set.remove(item.value);
		m_queue.pop_back();
		m_queue_length--;
	}

	Value& get_value()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::get_value(): Empty");
		return m_queue.back().value;
	}

	float get_f()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::get_f(): Empty");
		return m_queue.back().f;
	}

	float get_fw()
	{
		if(m_queue.empty())
			throw Exception("SpatialUpdateQueue::get_fw(): Empty");
		return m_queue.back().fw;
	}

	size_t get_length()
	{
		return m_queue_length;
	}
};

bool SpatialUpdateQueue::Item::operator>(const Item &other) const
{
	if(f > 1.0f && other.f <= 1.0f)
		return true;
	if(f <= 1.0f && other.f > 1.0f)
		return false;
	return fw > other.fw;
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
	LuaSUQ::register_metatable(L);

	DEF_BUILDAT_FUNC(SpatialUpdateQueue);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
