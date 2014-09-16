#pragma once
#include "server/rccpp.h"

class TestClass : public RuntimeClass<TestClass> {
	CLASS_INTERNALS(TestClass)
public:
	TestClass();
	~TestClass();
	RUNTIME_VIRTUAL int test_add(int a);
	
	int m_sum;
};

RUNTIME_EXPORT_CLASS(TestClass)

/*class Module : public RuntimeClass<Module> {
	CLASS_INTERNALS(Module)
public:
	Module();
	~Module();
	RUNTIME_VIRTUAL int test_add(int a);
	
	int m_sum;
};

RUNTIME_EXPORT_CLASS(Module)*/
