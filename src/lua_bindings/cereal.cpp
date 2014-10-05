// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#define MODULE "lua_bindings"

namespace lua_bindings {

/* Type format:
{"object",
	{"peer", "int32_t"},
	{"players", {"unordered_map",
		"int32_t",
		{"object",
			{"peer", "int32_t"},
			{"x", "int32_t"},
			{"y", "int32_t"},
		},
	}},
	{"playfield", {"object",
		{"w", "int32_t"},
		{"h", "int32_t"},
		{"tiles", {"array", "int32_t"}},
	}},
}) */

static constexpr auto known_types =
		"byte, int32_t, double, array, unordered_map, object";

// Places result value on top of stack
static void binary_input_read_value(lua_State *L, int type_L,
		cereal::PortableBinaryInputArchive &ar)
{
	if(type_L < 0) type_L = lua_gettop(L) + type_L + 1;

	// Read value definition
	bool has_table = false;
	ss_ outfield_type;
	if(lua_istable(L, type_L)){
		has_table = true;
		lua_rawgeti(L, type_L, 1);
		outfield_type = lua_tocppstring(L, -1);
		lua_pop(L, 1);
	} else if(lua_isstring(L, type_L)){
		outfield_type = lua_tocppstring(L, type_L);
	} else {
		throw Exception("Value definition table or string expected");
	}

	log_t(MODULE, "binary_input_read_value(): type=%s", cs(outfield_type));

	if(outfield_type == "byte"){
		uchar value;
		ar(value);
		log_t(MODULE, "byte value=%i", (int)value);
		lua_pushinteger(L, value);
		// value is left on stack
	} else if(outfield_type == "int32_t"){
		int32_t value;
		ar(value);
		log_t(MODULE, "int32_t value=%i", value);
		lua_pushinteger(L, value);
		// value is left on stack
	} else if(outfield_type == "double"){
		double value;
		ar(value);
		log_t(MODULE, "double value=%f", value);
		lua_pushnumber(L, value);
		// value is left on stack
	} else if(outfield_type == "string"){
		ss_ value;
		ar(value);
		log_t(MODULE, "string value=%s", cs(value));
		lua_pushlstring(L, value.c_str(), value.size());
		// value is left on stack
	} else if(outfield_type == "array"){
		if(!has_table)
			throw Exception("array requires parameter table");
		lua_newtable(L);
		int value_result_table_L = lua_gettop(L);
		lua_rawgeti(L, type_L, 2);
		int array_type_L = lua_gettop(L);
		// Loop through array items
		uint64_t num_entries;
		ar(num_entries);
		for(uint64_t i = 0; i < num_entries; i++){
			log_t(MODULE, "array[%s]", cs(i));
			binary_input_read_value(L, array_type_L, ar);
			lua_rawseti(L, value_result_table_L, i + 1);
		}
		lua_pop(L, 1); // array_type_L
		// value_result_table_L is left on stack
	} else if(outfield_type == "unordered_map"){
		if(!has_table)
			throw Exception("unordered_map requires parameter table");
		lua_newtable(L);
		int value_result_table_L = lua_gettop(L);
		lua_rawgeti(L, type_L, 2);
		int map_key_type_L = lua_gettop(L);
		lua_rawgeti(L, type_L, 3);
		int map_value_type_L = lua_gettop(L);
		// Loop through map entries
		uint64_t num_entries;
		ar(num_entries);
		for(uint64_t i = 0; i < num_entries; i++){
			log_t(MODULE, "unordered_map[%s]", cs(i));
			binary_input_read_value(L, map_key_type_L, ar);
			binary_input_read_value(L, map_value_type_L, ar);
			lua_rawset(L, value_result_table_L);
		}
		lua_pop(L, 1); // map_value_type_L
		lua_pop(L, 1); // map_key_type_L
		// value_result_table_L is left on stack
	} else if(outfield_type == "object"){
		if(!has_table)
			throw Exception("object requires parameter table");
		lua_newtable(L);
		int value_result_table_L = lua_gettop(L);
		// Loop through object fields
		size_t field_i = 0;
		lua_pushnil(L);
		while(lua_next(L, type_L) != 0){
			if(field_i != 0){
				log_t(MODULE, "object field %zu", field_i);
				int field_def_L = lua_gettop(L);
				lua_rawgeti(L, field_def_L, 1); // name
				lua_rawgeti(L, field_def_L, 2); // type
				log_t(MODULE, " = object[\"%s\"]", lua_tostring(L, -2));
				binary_input_read_value(L, -1, ar); // Uses type, pushes value
				lua_remove(L, -2); // Remove type
				lua_rawset(L, value_result_table_L); // Set t[#-2] = #-1
			}
			lua_pop(L, 1); // Continue iterating by popping table value
			field_i++;
		}
		// value_result_table_L is left on stack
	} else {
		throw Exception(ss_()+"Unknown type \""+outfield_type+"\""
				"; known types are "+known_types);
	}
}

static void binary_output_write_value(lua_State *L, int value_L, int type_L,
		cereal::PortableBinaryOutputArchive &ar)
{
	if(value_L < 0) value_L = lua_gettop(L) + value_L + 1;
	if(type_L < 0) type_L = lua_gettop(L) + type_L + 1;

	// Read value definition
	bool has_table = false;
	ss_ outfield_type;
	if(lua_istable(L, type_L)){
		has_table = true;
		lua_rawgeti(L, type_L, 1);
		outfield_type = lua_tocppstring(L, -1);
		lua_pop(L, 1);
	} else if(lua_isstring(L, type_L)){
		outfield_type = lua_tocppstring(L, type_L);
	} else {
		throw Exception("Value definition table or string expected");
	}

	log_t(MODULE, "binary_output_write_value(): type=%s", cs(outfield_type));

	if(outfield_type == "byte"){
		uchar value = lua_tointeger(L, value_L);
		log_t(MODULE, "byte value=%i", (int)value);
		ar(value);
	} else if(outfield_type == "int32_t"){
		int32_t value = lua_tointeger(L, value_L);
		log_t(MODULE, "int32_t value=%i", value);
		ar(value);
	} else if(outfield_type == "double"){
		double value = lua_tonumber(L, value_L);
		log_t(MODULE, "double value=%f", value);
		ar(value);
	} else if(outfield_type == "string"){
		ss_ value = lua_tocppstring(L, value_L);
		log_t(MODULE, "string value=%s", cs(value));
		ar(value);
	} else if(outfield_type == "array"){
		if(!has_table)
			throw Exception("array requires parameter table");
		lua_rawgeti(L, type_L, 2);
		int array_type_L = lua_gettop(L);
		// Loop through array items
		uint64_t num_entries = 0;
		lua_pushnil(L);
		while(lua_next(L, value_L) != 0){
			lua_pop(L, 1); // Continue iterating by popping table value
			num_entries++;
		}
		ar(num_entries);
		lua_pushnil(L);
		int i = 1;
		while(lua_next(L, value_L) != 0){
			log_t(MODULE, "array[%i]", i);
			binary_output_write_value(L, -1, array_type_L, ar);
			lua_pop(L, 1); // Continue iterating by popping table value
			i++;
		}
		lua_pop(L, 1); // array_type_L
		// value_result_table_L is left on stack
	} else if(outfield_type == "unordered_map"){
		if(!has_table)
			throw Exception("unordered_map requires parameter table");
		lua_rawgeti(L, type_L, 2);
		int map_key_type_L = lua_gettop(L);
		lua_rawgeti(L, type_L, 3);
		int map_value_type_L = lua_gettop(L);
		// Loop through map entries
		uint64_t num_entries = 0;
		lua_pushnil(L);
		while(lua_next(L, value_L) != 0){
			lua_pop(L, 1); // Continue iterating by popping table value
			num_entries++;
		}
		ar(num_entries);
		lua_pushnil(L);
		while(lua_next(L, value_L) != 0){
			int key_L = lua_gettop(L) - 1;
			int value_L = lua_gettop(L);
			log_t(MODULE, "unordered_map[%s]", lua_tostring(L, key_L));
			binary_output_write_value(L, key_L, map_key_type_L, ar);
			binary_output_write_value(L, value_L, map_value_type_L, ar);
			lua_pop(L, 1); // Continue iterating by popping table value
		}
		lua_pop(L, 1); // map_value_type_L
		lua_pop(L, 1); // map_key_type_L
		// value_result_table_L is left on stack
	} else if(outfield_type == "object"){
		if(!has_table)
			throw Exception("object requires parameter table");
		// Loop through object fields
		size_t field_i = 0;
		lua_pushnil(L);
		while(lua_next(L, type_L) != 0){
			if(field_i != 0){
				log_t(MODULE, "object field %zu", field_i);
				int field_def_L = lua_gettop(L);
				lua_rawgeti(L, field_def_L, 2); // type
				lua_rawgeti(L, field_def_L, 1); // name
				log_t(MODULE, " = object[\"%s\"]", lua_tostring(L, -1));
				// Get value_L[name]; name is replaced by value
				lua_rawget(L, value_L);
				// Recurse into this value
				binary_output_write_value(L, -1, -2, ar);
				lua_pop(L, 1); // Pop value
				lua_pop(L, 1); // Pop type
			}
			lua_pop(L, 1); // Continue iterating by popping table value
			field_i++;
		}
	} else {
		throw Exception(ss_()+"Unknown type \""+outfield_type+"\""
				"; known types are "+known_types);
	}
}

// cereal_binary_input(data: string, types: table) -> table of values
static int l_cereal_binary_input(lua_State *L)
{
	size_t data_len = 0;
	const char *data_c = lua_tolstring(L, 1, &data_len);
	ss_ data(data_c, data_len);

	int type_L = 2;

	std::istringstream is(data, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);

	binary_input_read_value(L, type_L, ar);

	return 1;
}

// cereal_binary_output(values: table, types: table) -> data
static int l_cereal_binary_output(lua_State *L)
{
	int value_L = 1;

	int type_L = 2;

	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);

		binary_output_write_value(L, value_L, type_L, ar);
	}
	ss_ data = os.str();
	lua_pushlstring(L, data.c_str(), data.size());
	return 1;
}

void init_cereal(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){\
	lua_pushcfunction(L, l_##name);\
	lua_setglobal(L, "__buildat_" #name);\
}
	DEF_BUILDAT_FUNC(cereal_binary_input)
	DEF_BUILDAT_FUNC(cereal_binary_output)
}

} // namespace lua_bindingss
// vim: set noet ts=4 sw=4:

