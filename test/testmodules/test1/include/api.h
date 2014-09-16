#include "interface/event.h"

namespace test1
{
	struct Thing: public interface::Event::Private
	{
		ss_ some_data;

		Thing(const ss_ &some_data="default value"): some_data(some_data) {}
	};
}
