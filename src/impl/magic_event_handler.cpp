// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/magic_event_handler.h"
#include "core/log.h"
#include <SceneEvents.h>
#include <PhysicsEvents.h>
#include <IOEvents.h>
#include <Node.h>
#include <Component.h>
#include <RigidBody.h>

#define ERASE_FIELD(name){\
	event_data.Erase(#name);\
}

#define POINTER_TO_ID(type, name){\
	type *pointer = static_cast<type*>(event_data[#name].GetVoidPtr());\
	event_data[#name "ID"] = pointer->GetID();\
	event_data.Erase(#name);\
}

namespace interface {

using namespace Urho3D;

void MagicEventHandler::on_event(StringHash event_type, VariantMap &event_data)
{
	auto *evreg = interface::getGlobalEventRegistry();
	if(log_get_max_level() >= CORE_DEBUG){
		log_d(MODULE, "MagicEventHandler::on_event(): %s (%zu)",
				cs(evreg->name(m_buildat_event_type)), m_buildat_event_type);
	}

	// Convert pointers to IDs because the event will be queued for later
	// handling and pointers may become invalid. This operates like a
	// whitelist because passing the pointers around is so unsafe it's
	// going to cause way too much trouble.

	if(event_type == E_LOGMESSAGE){
		emit_event(event_type, event_data);
		return;
	}
	if(event_type == E_NODEADDED || event_type == E_NODEREMOVED){
		POINTER_TO_ID(Node, Parent);
		POINTER_TO_ID(Node, Node);
		emit_event(event_type, event_data);
		return;
	}
	if(event_type == E_COMPONENTADDED || event_type == E_COMPONENTREMOVED){
		POINTER_TO_ID(Node, Node);
		POINTER_TO_ID(Component, Component);
		emit_event(event_type, event_data);
		return;
	}
	if(event_type == E_PHYSICSCOLLISIONSTART){
		ERASE_FIELD(World);
		POINTER_TO_ID(Node, NodeA);
		POINTER_TO_ID(Node, NodeB);
		POINTER_TO_ID(RigidBody, BodyA);
		POINTER_TO_ID(RigidBody, BodyB);
		emit_event(event_type, event_data);
		return;
	}
	if(event_type == E_PHYSICSCOLLISION){
		ERASE_FIELD(World);
		POINTER_TO_ID(Node, NodeA);
		POINTER_TO_ID(Node, NodeB);
		POINTER_TO_ID(RigidBody, BodyA);
		POINTER_TO_ID(RigidBody, BodyB);
		emit_event(event_type, event_data);
		return;
	}

	throw Exception(ss_()+"MagicEventHandler::on_event(): Urho3D event "
			"not whitelisted: "+cs(evreg->name(m_buildat_event_type)));
}


}
// vim: set noet ts=4 sw=4:
