#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include <iostream>

using interface::Event;

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

	void event(const interface::Event &event)
	{
		switch(event.type){
		case Event::Type::START:
			start();
			break;
		}
	}

	int test_add(int a, int b)
	{
		return a + b;
	}

	void start()
	{
	}
};

extern "C" {
EXPORT void* createModule_test1(interface::Server *server)
{
	return (void*)(new Module());
}
}
