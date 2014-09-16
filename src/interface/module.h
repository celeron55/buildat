#pragma once
#include "core/types.h"

#define EXPORT __attribute__ ((visibility ("default")))

namespace interface
{
	struct Module
	{
		virtual ~Module(){};
		virtual int test_add(int a, int b) = 0;
	};
}
