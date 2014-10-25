// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"
#include <Object.h>
#include <Variant.h>
#include <StringHash.h>
#include <functional>

namespace interface
{
	namespace magic = Urho3D;

	struct MagicEvent: public interface::Event::Private {
		magic::StringHash magic_type;
		magic::VariantMap magic_data;
		MagicEvent(magic::StringHash magic_type,
				const magic::VariantMap &magic_data):
			magic_type(magic_type), magic_data(magic_data){}
	};
}
// vim: set noet ts=4 sw=4:
