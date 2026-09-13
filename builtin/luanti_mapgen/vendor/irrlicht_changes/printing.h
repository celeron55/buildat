// A shim, not Luanti's: see README.txt.
//
// Luanti prints a vector into a log stream; this is that, and nothing else.
#pragma once
#include "../irr_v3d.h"
#include "../irr_v2d.h"
#include <ostream>

template<class T>
std::ostream& operator<<(std::ostream &os, const core::vector3d<T> &v)
{
	return os<<"("<<v.X<<","<<v.Y<<","<<v.Z<<")";
}

template<class T>
std::ostream& operator<<(std::ostream &os, const core::vector2d<T> &v)
{
	return os<<"("<<v.X<<","<<v.Y<<")";
}
