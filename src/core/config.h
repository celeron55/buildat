// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/json.h"

namespace core
{
	struct Config
	{
		json::Value defaults;
		json::Value values;

		Config():
			defaults(json::object()),
			values(json::object())
		{}

		template<typename T>
		void set_default(const ss_ &name, const T &native_v)
		{
			json::Value new_v(native_v);

			const json::Value &current_v = values.get(name);
			if(!current_v.is_undefined() &&
					current_v.get_type() != new_v.get_type()){
				throw Exception(ss_()+"Cannot set defaults["+name+"] with type "+
						new_v.desc_type()+"; value already exists with type "+
						current_v.desc_type());
			}

			defaults.set(name, new_v);
		}

		template<typename T>
		void set(const ss_ &name, const T &native_v)
		{
			json::Value new_v(native_v);

			const json::Value &default_v = defaults.get(name);
			if(!default_v.is_undefined() &&
					new_v.get_type() != default_v.get_type()){
				throw Exception(ss_()+"Cannot set values["+name+"] with type "+
						new_v.desc_type()+"; default determines required type "+
						default_v.desc_type());
			}

			values.set(name, new_v);
		}

		template<typename T>
		const T& get(const ss_ &name) const
		{
			const json::Value &current_v = values.get(name);
			if(current_v.is_undefined()){
				// Try default
				const json::Value &default_v = defaults.get(name);
				if(!default_v.is_undefined())
					return default_v.as<T>();
				throw Exception("Configuration value \""+name+"\" not found");
			}
			return current_v.as<T>();
		}
	};
}
// vim: set noet ts=4 sw=4:
