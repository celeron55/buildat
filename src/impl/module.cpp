// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/module.h"

namespace interface {

void* Module::check_interface()
{
	void *i = get_interface();
	if(!i)
		throw Exception(ss_()+"Module \""+m_module_name+"\" has no interface");
	return i;
}

}
// vim: set noet ts=4 sw=4:
