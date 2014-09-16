#include "interface/module.h"
#include "interface/server.h"
#include <iostream>

struct Module: public interface::Module
{
	Module()
	{
		std::cout<<"test1 construct"<<std::endl;
	}

	~Module()
	{
		std::cout<<"test1 destruct"<<std::endl;
	}

	void start()
	{
	}

	int test_add(int a, int b)
	{
		return a + b;
	}
};

extern "C" {
EXPORT void* createModule_test1(interface::Server *server)
{
	return (void*)(new Module());
}
}
