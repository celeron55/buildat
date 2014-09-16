#include "interface/module.h"
#include "interface/server.h"

struct Module: public interface::Module
{
	Module()
	{
	}

	~Module()
	{
	}

	int test_add(int a, int b)
	{
		return a + b;
	}
};

extern "C" {
EXPORT void* createModule(interface::Server *server)
{
	return (void*)(new Module());
}
}
