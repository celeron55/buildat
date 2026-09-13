// A shim, not Luanti's: see ../README.txt.
//
// The mapgen uses none of Luanti's containers itself; this is here because
// mapgen.h includes it.
#ifndef LUANTI_SHIM_UTIL_CONTAINER_H
#define LUANTI_SHIM_UTIL_CONTAINER_H
#include "../irrlichttypes.h"
#include <map>
#include <queue>
#include <set>

// A queue that holds each value once, which is what the liquid pass walks
template<typename Value> class UniqueQueue
{
public:
	bool empty() const { return m_queue.empty(); }
	size_t size() const { return m_queue.size(); }

	void push_back(const Value &v){
		if(m_set.insert(v).second)
			m_queue.push(v);
	}

	Value pop_front(){
		Value v = m_queue.front();
		m_queue.pop();
		m_set.erase(v);
		return v;
	}

private:
	std::set<Value> m_set;
	std::queue<Value> m_queue;
};

#endif
