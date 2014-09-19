// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include <smallsha1.h>

namespace interface {
namespace sha1 {

ss_ calculate(const ss_ &data)
{
	unsigned char result[20];
	smallsha1::calc(data.c_str(), data.size(), result);
	return ss_((char*)result, 20);
}

ss_ hex(const ss_ &raw)
{
	if(raw.size() != 20)
		throw Exception("interface::sha1::hex() only accepts raw.size()=20");
	char result[41];
	smallsha1::toHexString((const unsigned char*)raw.c_str(), result);
	return ss_(result, 40);
}

}
}
