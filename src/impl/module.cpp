#include "interface/module.h"

namespace interface {

void* Module::check_interface()
{
	void *i = get_interface();
	if(!i)
		throw Exception(ss_()+"Module \""+MODULE+"\" has no interface");
	return i;
}

}
