#pragma once
#include "server/rccpp.h"

class Module : public RuntimeClass<Module> {
	CLASS_INTERNALS(Module)
public:
	Module();
	~Module();
	RUNTIME_VIRTUAL int test_add(int a, int b);
};
RUNTIME_EXPORT_MODULE(Module)

