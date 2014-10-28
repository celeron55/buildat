// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/event.h"
#include "interface/mutex.h"

namespace interface {

Event::Type Event::t(const ss_ &name)
{
	return getGlobalEventRegistry()->type(name);
}

struct CEventRegistry: public EventRegistry
{
	sm_<ss_, Event::Type> m_types;
	Event::Type m_next_type = 1;
	interface::Mutex m_mutex;

	Event::Type type(const ss_ &name)
	{
		interface::MutexScope ms(m_mutex);
		auto it = m_types.find(name);
		if(it != m_types.end())
			return it->second;
		m_types[name] = m_next_type++;
		return m_next_type - 1;
	}

	ss_ name(const Event::Type &type)
	{
		interface::MutexScope ms(m_mutex);
		for(auto &pair : m_types){
			if(pair.second == type)
				return pair.first;
		}
		return "";
	}
};

EventRegistry* getGlobalEventRegistry()
{
	static CEventRegistry c;
	return &c;
}
}
// vim: set noet ts=4 sw=4:
