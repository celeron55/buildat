#include "server/rccpp.h"

class Test1Module : public RuntimeClass<Test1Module> {
	CLASS_INTERNALS(Test1Module)
public:
	Test1Module();
	~Test1Module();
	RUNTIME_VIRTUAL int test_add(int a, int b);
};
RUNTIME_EXPORT_MODULE(Test1Module)

Test1Module::Test1Module()
{
}

Test1Module::~Test1Module()
{
}

int Test1Module::test_add(int a, int b)
{
	return a + b;
}

