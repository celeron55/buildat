// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "entitysync/api.h"
#include "core/log.h"
#include "network/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "interface/magic_event.h"
#include <Object.h>
#include <Context.h>
#include <Engine.h>
#include <Variant.h>
#include <Scene.h>
#include <ResourceCache.h>
#include <CoreEvents.h>
#include <SceneEvents.h>
#include <ReplicationState.h>
#include <Component.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>

using interface::Event;
namespace magic = Urho3D;
using magic::Node;
using magic::Scene;
using magic::Component;

namespace entitysync {

ss_ dump(const magic::VectorBuffer &buf)
{
	std::ostringstream os(std::ios::binary);
	os<<"[";
	for(size_t i = 0; i < buf.GetBuffer().Size(); i++){
		if(i != 0)
			os<<", ";
		os<<cs(buf.GetBuffer().At(i));
	}
	os<<"]";
	return os.str();
}

ss_ buf_to_string(const magic::VectorBuffer &buf)
{
	return ss_((const char*)&buf.GetBuffer().Front(), buf.GetBuffer().Size());
}

struct Module: public interface::Module, public entitysync::Interface
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("entitysync"),
		m_server(server)
	{
		log_v(MODULE, "entitysync construct");
	}

	~Module()
	{
		log_v(MODULE, "entitysync destruct");
	}

	void init()
	{
		log_v(MODULE, "entitysync init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
#if 0
		m_server->sub_magic_event(this, magic::E_NODEADDED,
				Event::t("entitysync:node_added"));
		m_server->sub_magic_event(this, magic::E_NODEREMOVED,
				Event::t("entitysync:node_removed"));
		m_server->sub_magic_event(this, magic::E_COMPONENTADDED,
				Event::t("entitysync:component_added"));
		m_server->sub_magic_event(this, magic::E_COMPONENTREMOVED,
				Event::t("entitysync:component_removed"));
#endif
		m_server->access_scene([&](magic::Scene *scene,
				magic::SceneReplicationState &scene_state)
		{
			magic::Context *context = scene->GetContext();

			/*magic::ResourceCache* cache =
					m_context->GetSubsystem<magic::ResourceCache>();

			Node* plane_node = m_scene->CreateChild("Plane");
			plane_node->SetScale(Vector3(100.0f, 1.0f, 100.0f));
			StaticModel* plane_object = plane_node->CreateComponent<StaticModel>();
			plane_object->SetModel(cache->GetResource<Model>("Models/Plane.mdl"));
			plane_object->SetMaterial(cache->GetResource<Material>("Materials/StoneTiled.xml"));*/
		});
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start",			on_start)
		EVENT_VOIDN("core:unload",		   on_unload)
		EVENT_VOIDN("core:continue",		 on_continue)
		EVENT_TYPEN("core:tick",			 on_tick, interface::TickEvent)
#if 0
		EVENT_TYPEN("entitysync:node_added",
				on_node_added, interface::MagicEvent)
		EVENT_TYPEN("entitysync:node_removed",
				on_node_removed, interface::MagicEvent)
		EVENT_TYPEN("entitysync:component_added",
				on_component_added, interface::MagicEvent)
		EVENT_TYPEN("entitysync:component_removed",
				on_component_removed, interface::MagicEvent)
#endif
	}

	void on_start()
	{
	}

	void on_unload()
	{
	}

	void on_continue()
	{
	}

	void on_tick(const interface::TickEvent &event)
	{
		log_d(MODULE, "entitytest::on_tick");

		m_server->access_scene([&](magic::Scene *scene,
				magic::SceneReplicationState &scene_state)
		{
			scene->PrepareNetworkUpdate(); // ?

			magic::HashSet<uint> nodes_to_process;
			uint scene_id = scene->GetID();
			nodes_to_process.Insert(scene_id);
			sync_node(scene_id, nodes_to_process, scene, scene_state);

			nodes_to_process.Insert(scene_state.dirtyNodes_);
			nodes_to_process.Erase(scene_id);

			while(!nodes_to_process.Empty()){
				uint node_id = nodes_to_process.Front();
				sync_node(node_id, nodes_to_process, scene, scene_state);
			}
		});
	}

	void sync_node(
			uint node_id, magic::HashSet<uint> &nodes_to_process,
			magic::Scene *scene, magic::SceneReplicationState &scene_state)
	{
		if(!nodes_to_process.Erase(node_id))
			return;
		log_d(MODULE, "sync_node(): node_id=%zu", node_id);
		auto it = scene_state.nodeStates_.Find(node_id);
		if(it == scene_state.nodeStates_.End()){
			// New node
			Node *n = scene->GetNode(node_id);
			if(n){
				sync_new_node(n, nodes_to_process, scene, scene_state);
			} else {
				// Was already deleted
				log_w(MODULE, "New node was already deleted: %zu", node_id);
				scene_state.dirtyNodes_.Erase(node_id);
			}
		} else {
			// Existing node
			magic::NodeReplicationState &node_state = it->second_;
			Node *n = node_state.node_;
			if(!n){
				// Deleted
				throw Exception("Deleted node not implemented");
			} else {
				sync_existing_node(n, node_state, nodes_to_process,
						scene, scene_state);
			}
		}
	}

	void sync_new_node(Node *node,
			magic::HashSet<uint> &nodes_to_process,
			Scene *scene, magic::SceneReplicationState &scene_state)
	{
		log_v(MODULE, "sync_new_node(): %zu", node->GetID());
		auto &deps = node->GetDependencyNodes();
		for(auto it = deps.Begin(); it != deps.End(); ++it){
			uint node_id = (*it)->GetID();
			if(scene_state.dirtyNodes_.Contains(node_id))
				sync_node(node_id, nodes_to_process, scene, scene_state);
		}

		// TODO: One replication state for each client(?)
		magic::NodeReplicationState &node_state =
				scene_state.nodeStates_[node->GetID()];
		//node_state.connection_ = nullptr;
		node_state.sceneState_ = &scene_state;
		node_state.node_ = node;
		node->AddReplicationState(&node_state);

		magic::VectorBuffer buf;
		buf.WriteNetID(node->GetID());
		node->WriteInitialDeltaUpdate(buf);

		// TODO: User variables (see Network/Connection.cpp)
		buf.WriteVLE(0);

		// Components
		buf.WriteVLE(node->GetNumNetworkComponents());
		auto &components = node->GetComponents();
		for(uint i = 0; i<components.Size(); i++){
			Component *component = components[i];
			if(component->GetID() >= magic::FIRST_LOCAL_ID)
				continue;
			magic::ComponentReplicationState &component_state =
					node_state.componentStates_[component->GetID()];
			//component_state.connection_ = nullptr;
			component_state.nodeState_ = &node_state;
			component_state.component_ = component;
			component->AddReplicationState(&component_state);
			buf.WriteStringHash(component->GetType());
			buf.WriteNetID(component->GetID());
			component->WriteInitialDeltaUpdate(buf);
		}

		send_to_all("entitysync:new_node", buf);

		node_state.markedDirty_ = false;
		scene_state.dirtyNodes_.Erase(node->GetID());
	}

	void sync_existing_node(
			Node *node, magic::NodeReplicationState &node_state,
			magic::HashSet<uint> &nodes_to_process,
			Scene *scene, magic::SceneReplicationState &scene_state)
	{
		log_v(MODULE, "sync_existing_node(): %zu", node->GetID());
		auto &deps = node->GetDependencyNodes();
		for(auto it = deps.Begin(); it != deps.End(); ++it){
			uint node_id = (*it)->GetID();
			if(scene_state.dirtyNodes_.Contains(node_id))
				sync_node(node_id, nodes_to_process, scene, scene_state);
		}

		// Handle changed attributes
		if(node_state.dirtyAttributes_.Count()){
			log_v(MODULE, "sync_existing_node(): %zu: Changed attributes",
					node->GetID());
			const magic::Vector<magic::AttributeInfo> &attributes =
					*node->GetNetworkAttributes();
			uint num = attributes.Size();
			bool has_latest_data = false;

			// ?
			for(uint i = 0; i < num; i++){
				if(node_state.dirtyAttributes_.IsSet(i) &&
						(attributes.At(i).mode_ & magic::AM_LATESTDATA)){
					has_latest_data = true;
					node_state.dirtyAttributes_.Clear(i);
				}
			}

			// ?
			if(has_latest_data){
				magic::VectorBuffer buf;

				buf.WriteNetID(node->GetID());
				node->WriteLatestDataUpdate(buf);

				send_to_all("entitysync:latest_node_data", buf);
			}

			// ?
			if(node_state.dirtyAttributes_.Count() || node_state.dirtyVars_.Size()){
				magic::VectorBuffer buf;

				buf.WriteNetID(node->GetID());
				node->WriteDeltaUpdate(buf, node_state.dirtyAttributes_);

				// Variables (see Network/Connection.cpp)
				buf.WriteVLE(node_state.dirtyVars_.Size());
				const magic::VariantMap &vars = node->GetVars();
				const magic::HashSet<magic::StringHash> &dirty_vars =
						node_state.dirtyVars_;
				for(auto it = dirty_vars.Begin(); it != dirty_vars.End(); ++it){
					auto var_it = vars.Find(*it);
					if(var_it != vars.End()){
						buf.WriteStringHash(var_it->first_);
						buf.WriteVariant(var_it->second_);
					} else {
						// Variable has been removed; send dummy data
						buf.WriteStringHash(magic::StringHash());
						buf.WriteVariant(magic::Variant::EMPTY);
					}
				}

				send_to_all("entitysync:latest_node_data", buf);
			}

			node_state.dirtyAttributes_.ClearAll();
			node_state.dirtyVars_.Clear();
		}

		// TODO: Handle changed or removed components
	
		node_state.markedDirty_ = false;
		scene_state.dirtyNodes_.Erase(node->GetID());
	}

	void send_to_all(const ss_ &name, const magic::VectorBuffer &buf)
	{
		log_i(MODULE, "%s: Update size: %zu, data=%s",
				cs(name), buf.GetBuffer().Size(), cs(dump(buf)));
		ss_ data = buf_to_string(buf);
		network::access(m_server, [&](network::Interface * inetwork){
			auto peers = inetwork->list_peers();
			for(auto &peer : peers)
				inetwork->send(peer, name, data);
		});
	}

#if 0
	void on_node_added(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		uint node_id = event_data["NodeID"].GetInt();
		log_v(MODULE, "Node added: %i", node_id);
		m_server->access_scene([&](magic::Scene *scene,
				magic::SceneReplicationState &scene_state)
		{
			magic::Node *n = scene->GetNode(node_id);
			if(!n) // TODO: Just warn or ignore
				throw Exception("Added node not found");
			magic::NodeReplicationState &node_state =
					scene_state.nodeStates_[node_id];
			//node_state.connection_ = nullptr;
			node_state.sceneState_ = &scene_state;
			node_state.node_ = n;
			n->AddReplicationState(&node_state);
			n->PrepareNetworkUpdate();

			magic::VectorBuffer buf;
			buf.WriteNetID(node_id);
			n->WriteInitialDeltaUpdate(buf);
			sv_<int> v(&buf.GetBuffer().Front(),
					(&buf.GetBuffer().Front()) + buf.GetBuffer().Size());
			log_i(MODULE, "enttytest::on_node_added: Delta update size: %zu, data=%s",
					buf.GetBuffer().Size(), cs(dump(v)));
		});
	}

	void on_node_removed(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_v(MODULE, "Node removed: %i", event_data["NodeID"].GetInt());
	}

	void on_component_added(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_v(MODULE, "Component added: %i", event_data["ComponentID"].GetInt());
	}

	void on_component_removed(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_v(MODULE, "Component removed: %i", event_data["ComponentID"].GetInt());
	}
#endif

	// Interface

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	EXPORT void* createModule_entitysync(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
