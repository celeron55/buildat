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
	// The names by type, [0] none
	sv_<ss_> m_names{""};
	interface::Mutex m_mutex;

	Event::Type type(const ss_ &name)
	{
		interface::MutexScope ms(m_mutex);
		auto it = m_types.find(name);
		if(it != m_types.end())
			return it->second;
		m_types[name] = m_names.size();
		m_names.push_back(name);
		return m_names.size() - 1;
	}

	Event::Type find(const ss_ &name)
	{
		interface::MutexScope ms(m_mutex);
		auto it = m_types.find(name);
		return it != m_types.end() ? it->second : 0;
	}

	ss_ name(const Event::Type &type)
	{
		interface::MutexScope ms(m_mutex);
		return type < m_names.size() ? m_names[type] : "";
	}
};

EventRegistry* getGlobalEventRegistry()
{
	static CEventRegistry c;
	return &c;
}
}
// vim: set noet ts=4 sw=4:
