// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Object.h>
#include <Variant.h>
#include <StringHash.h>
#pragma GCC diagnostic pop
#include <functional>

namespace interface
{
	namespace magic = Urho3D;

	struct MagicEvent: public interface::Event::Private {
		magic::StringHash event_type;
		magic::VariantMap event_data;
		MagicEvent(magic::StringHash event_type, const magic::VariantMap &event_data):
			event_type(event_type), event_data(event_data){}
	};
}
// vim: set noet ts=4 sw=4:
