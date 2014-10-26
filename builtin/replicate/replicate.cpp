// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "replicate/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "core/log.h"
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

namespace replicate {

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

struct Module: public interface::Module, public replicate::Interface
{
	interface::Server *m_server;
	// NOTE: We use pointers to SceneReplicationStates as Connection pointers in
	//       other replication states in order to scene->CleanupConnection()
	//       without an actual Connection object (which we don't want to use)
	sm_<PeerId, magic::SceneReplicationState> m_scene_states;

	sv_<Event> m_events_to_emit_after_next_sync;

	Module(interface::Server *server):
		interface::Module("replicate"),
		m_server(server)
	{
		log_d(MODULE, "replicate construct");
	}

	~Module()
	{
		log_d(MODULE, "replicate destruct");
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Scene *scene = imc->get_scene();
			for(auto &pair: m_scene_states){
				magic::SceneReplicationState &scene_state = pair.second;
				scene->CleanupConnection((magic::Connection*)&scene_state);
			}
		});
	}

	void init()
	{
		log_d(MODULE, "replicate init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("core:tick"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
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

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "replicate::on_client_connected: id=%zu",
				client_connected.info.id);
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		log_v(MODULE, "replicate::on_client_disconnected: id=%zu",
				old_client.info.id);
		auto peer = old_client.info.id;
		auto it = m_scene_states.find(peer);
		if(it == m_scene_states.end())
			return;
		magic::SceneReplicationState &scene_state = it->second;
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Scene *scene = imc->get_scene();
			// NOTE: We use pointers to SceneReplicationStates as Connection
			//       pointers in other replication states in order to
			//       scene->CleanupConnection() without an actual Connection object
			//       (which we don't want to use)
			scene->CleanupConnection((magic::Connection*)&scene_state);
			m_scene_states.erase(peer);
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		log_d(MODULE, "replicate::on_tick");

		sync_changes();

		for(Event &event : m_events_to_emit_after_next_sync){
			m_server->emit_event(std::move(event));
		}
		m_events_to_emit_after_next_sync.clear();
	}

	void sync_changes()
	{
		sv_<PeerId> peers;
		network::access(m_server, [&](network::Interface *inetwork){
			peers = inetwork->list_peers();
		});
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Scene *scene = imc->get_scene();
			// For a reference implementation of this kind of network
			// synchronization, see Urho3D's Network/Connection.cpp

			// Compare attributes and set replication states dirty as needed;
			// this accesses every replication state for every node.
			scene->PrepareNetworkUpdate();

			// Send changes to each peer (each of which has its own replication
			// state)
			for(auto &peer: peers){
				magic::SceneReplicationState &scene_state = m_scene_states[peer];

				magic::HashSet<uint> nodes_to_process;
				uint scene_id = scene->GetID();
				nodes_to_process.Insert(scene_id);
				sync_node(peer, scene_id, nodes_to_process, scene, scene_state);

				nodes_to_process.Insert(scene_state.dirtyNodes_);
				nodes_to_process.Erase(scene_id);

				while(!nodes_to_process.Empty()){
					uint node_id = nodes_to_process.Front();
					sync_node(peer, node_id, nodes_to_process, scene,
							scene_state);
				}
			}
		});
	}

	void sync_node(PeerId peer,
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
				sync_create_node(peer, n, nodes_to_process, scene, scene_state);
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
				// Node was removed
				magic::VectorBuffer buf;
				buf.WriteNetID(node_id);
				send_to_peer(peer, "replicate:remove_node", buf);
			} else {
				sync_existing_node(peer, n, node_state, nodes_to_process,
						scene, scene_state);
			}
		}
	}

	void sync_create_node(PeerId peer, Node *node,
			magic::HashSet<uint> &nodes_to_process,
			Scene *scene, magic::SceneReplicationState &scene_state)
	{
		log_d(MODULE, "sync_create_node(): %zu", node->GetID());
		auto &deps = node->GetDependencyNodes();
		for(auto it = deps.Begin(); it != deps.End(); ++it){
			uint node_id = (*it)->GetID();
			if(scene_state.dirtyNodes_.Contains(node_id))
				sync_node(peer, node_id, nodes_to_process, scene, scene_state);
		}

		magic::NodeReplicationState &node_state =
				scene_state.nodeStates_[node->GetID()];
		node_state.connection_ = (magic::Connection*)&scene_state;
		node_state.sceneState_ = &scene_state;
		node_state.node_ = node;
		node->AddReplicationState(&node_state);

		magic::VectorBuffer buf;
		buf.WriteNetID(node->GetID());
		node->WriteInitialDeltaUpdate(buf);

		// User variables
		auto &vars = node->GetVars();
		buf.WriteVLE(vars.Size());
		for(auto it = vars.Begin(); it != vars.End(); ++it){
			buf.WriteStringHash(it->first_);
			buf.WriteVariant(it->second_);
		}

		// Components
		buf.WriteVLE(node->GetNumNetworkComponents());
		auto &components = node->GetComponents();
		for(uint i = 0; i<components.Size(); i++){
			Component *component = components[i];
			if(component->GetID() >= magic::FIRST_LOCAL_ID)
				continue;
			magic::ComponentReplicationState &component_state =
					node_state.componentStates_[component->GetID()];
			component_state.connection_ = (magic::Connection*)&scene_state;
			component_state.nodeState_ = &node_state;
			component_state.component_ = component;
			component->AddReplicationState(&component_state);
			buf.WriteStringHash(component->GetType());
			buf.WriteNetID(component->GetID());
			component->WriteInitialDeltaUpdate(buf);
		}

		send_to_peer(peer, "replicate:create_node", buf);

		node_state.markedDirty_ = false;
		scene_state.dirtyNodes_.Erase(node->GetID());
	}

	void sync_existing_node(PeerId peer,
			Node *node, magic::NodeReplicationState &node_state,
			magic::HashSet<uint> &nodes_to_process,
			Scene *scene, magic::SceneReplicationState &scene_state)
	{
		log_d(MODULE, "sync_existing_node(): %zu", node->GetID());
		auto &deps = node->GetDependencyNodes();
		for(auto it = deps.Begin(); it != deps.End(); ++it){
			uint node_id = (*it)->GetID();
			if(scene_state.dirtyNodes_.Contains(node_id))
				sync_node(peer, node_id, nodes_to_process, scene, scene_state);
		}

		// Handle changed attributes
		if(node_state.dirtyAttributes_.Count() || node_state.dirtyVars_.Size()){
			log_d(MODULE, "sync_existing_node(): %zu: Changed attributes "
					"or variables", node->GetID());
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

				send_to_peer(peer, "replicate:latest_node_data", buf);
			}

			// ?
			if(node_state.dirtyAttributes_.Count() || node_state.dirtyVars_.Size()){
				magic::VectorBuffer buf;

				buf.WriteNetID(node->GetID());
				node->WriteDeltaUpdate(buf, node_state.dirtyAttributes_);

				// Variables
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

				send_to_peer(peer, "replicate:node_delta_update", buf);
			}

			node_state.dirtyAttributes_.ClearAll();
			node_state.dirtyVars_.Clear();
		}

		// Handle changed or removed components
		magic::HashMap<unsigned, magic::ComponentReplicationState>
		&component_states = node_state.componentStates_;
		for(auto it = component_states.Begin(); it != component_states.End();){
			auto current_it = it++;
			uint component_id = current_it->first_;
			auto &component_state = current_it->second_;
			magic::Component *component = component_state.component_;
			if(!component){
				// Component was removed
				magic::VectorBuffer buf;
				buf.WriteNetID(component_id);
				send_to_peer(peer, "replicate:remove_component", buf);
				component_states.Erase(current_it);
				continue;
			}
			// Existing component
			// Handle changed attributes
			if(component_state.dirtyAttributes_.Count()){
				log_d(MODULE, "sync_existing_node(): %zu: Changed attributes"
						" in component %zu", node->GetID(), component_id);
				const magic::Vector<magic::AttributeInfo> &attributes =
						*component->GetNetworkAttributes();
				uint num = attributes.Size();
				bool has_latest_data = false;

				// ?
				for(uint i = 0; i < num; i++){
					if(component_state.dirtyAttributes_.IsSet(i) &&
							(attributes.At(i).mode_ & magic::AM_LATESTDATA)){
						has_latest_data = true;
						component_state.dirtyAttributes_.Clear(i);
					}
				}

				// ?
				if(has_latest_data){
					magic::VectorBuffer buf;

					buf.WriteNetID(component->GetID());
					component->WriteLatestDataUpdate(buf);

					send_to_peer(peer, "replicate:latest_component_data", buf);
				}

				// ?
				if(component_state.dirtyAttributes_.Count()){
					magic::VectorBuffer buf;

					buf.WriteNetID(component->GetID());
					component->WriteDeltaUpdate(buf,
							component_state.dirtyAttributes_);

					send_to_peer(peer, "replicate:component_delta_update", buf);

					component_state.dirtyAttributes_.ClearAll();
				}
			}
		}

		// Handle new components
		if(component_states.Size() != node->GetNumNetworkComponents()){
			const magic::Vector<magic::SharedPtr<Component>>
			&components = node->GetComponents();
			for(uint i = 0; i<components.Size(); i++){
				Component *component = components[i];
				if(component->GetID() >= magic::FIRST_LOCAL_ID)
					continue;
				auto it = component_states.Find(component->GetID());
				if(it != component_states.End())
					continue;
				magic::ComponentReplicationState &component_state =
						component_states[component->GetID()];
				component_state.connection_ = (magic::Connection*)&scene_state;
				component_state.nodeState_ = &node_state;
				component_state.component_ = component;
				component->AddReplicationState(&component_state);

				magic::VectorBuffer buf;
				buf.WriteNetID(component->GetID());
				buf.WriteStringHash(component->GetType());
				buf.WriteNetID(component->GetID());
				component->WriteInitialDeltaUpdate(buf);

				send_to_peer(peer, "replicate:create_component", buf);
			}
		}

		node_state.markedDirty_ = false;
		scene_state.dirtyNodes_.Erase(node->GetID());
	}

	void send_to_peer(PeerId peer, const ss_ &name, const magic::VectorBuffer &buf)
	{
		log_d(MODULE, "%s: Update size: %zu", cs(name), buf.GetBuffer().Size());
		ss_ data = buf_to_string(buf);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	/*void send_to_all(const ss_ &name, const magic::VectorBuffer &buf)
	{
	    log_i(MODULE, "%s: Update size: %zu, data=%s",
	            cs(name), buf.GetBuffer().Size(), cs(dump(buf)));
	    ss_ data = buf_to_string(buf);
	    network::access(m_server, [&](network::Interface * inetwork){
	        auto peers = inetwork->list_peers();
	        for(auto &peer : peers)
	            inetwork->send(peer, name, data);
	    });
	}*/

	// Interface

	sv_<PeerId> find_peers_that_know_node(uint node_id)
	{
		sv_<PeerId> result;
		for(auto &pair : m_scene_states){
			PeerId peer_id = pair.first;
			magic::SceneReplicationState &scene_state = pair.second;
			auto &node_states = scene_state.nodeStates_;
			auto it = node_states.Find(node_id);
			if(it != node_states.End()){
				result.push_back(peer_id);
			}
		}
		return result;
	}

	void emit_after_next_sync(Event event)
	{
		m_events_to_emit_after_next_sync.push_back(std::move(event));
	}

	// TODO: Check if this is correctly implemented
	void sync_node_immediate(uint node_id)
	{
		sv_<PeerId> peers;
		network::access(m_server, [&](network::Interface *inetwork){
			peers = inetwork->list_peers();
		});
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Scene *scene = imc->get_scene();
			Node *n = scene->GetNode(node_id);
			n->PrepareNetworkUpdate();
			for(auto &peer: peers){
				magic::SceneReplicationState &scene_state = m_scene_states[peer];

				magic::HashSet<uint> nodes_to_process;
				nodes_to_process.Insert(node_id);

				while(!nodes_to_process.Empty()){
					uint node_id = nodes_to_process.Front();
					sync_node(peer, node_id, nodes_to_process, scene,
							scene_state);
				}
			}
		});
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_replicate(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
