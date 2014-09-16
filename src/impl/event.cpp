#include "interface/event.h"

namespace interface {

Event::Event(const ss_ &name, const sp_<Private> &p):
		type(getGlobalEventRegistry()->type(name)), p(p)
{}

struct CEventRegistry: public EventRegistry
{
	sm_<ss_, Event::Type> m_types;
	Event::Type m_next_type = 0;

	Event::Type type(const ss_ &name)
	{
		auto it = m_types.find(name);
		if(it != m_types.end())
			return it->second;
		m_types[name] = m_next_type++;
		return m_next_type - 1;
	}
};

EventRegistry* getGlobalEventRegistry()
{
	static CEventRegistry c;
	return &c;
}
}
