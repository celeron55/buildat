// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "main_context/api.h"
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/magic_event_handler.h"
#include "interface/os.h"
#include "interface/fs.h"
#include <Variant.h>
#include <Context.h>
#include <Engine.h>
#include <Scene.h>
#include <SceneEvents.h>
#include <Component.h>
#include <ReplicationState.h>
#include <PhysicsWorld.h>
#include <ResourceCache.h>
#include <Octree.h>
#include <Profiler.h>
#include <Log.h>
#include <IOEvents.h> // E_LOGMESSAGE
#include <Thread.h>
#include <climits>

namespace main_context {

using interface::Event;

class BuildatResourceRouter: public magic::ResourceRouter
{
	static constexpr const char *MODULE = "main_context";
	OBJECT(BuildatResourceRouter);

	interface::Server *m_server;
public:
	BuildatResourceRouter(magic::Context *context, interface::Server *server):
		magic::ResourceRouter(context),
		m_server(server)
	{}
	void Route(magic::String &name, magic::ResourceRequest requestType)
	{
		ss_ path = m_server->get_file_path(name.CString());
		if(path == ""){
			log_v(MODULE, "Resource route access: %s (assuming local file)",
					name.CString());
			return;
		}
		log_v(MODULE, "Resource route access: %s -> %s",
				name.CString(), cs(path));
		name = path.c_str();
	}
};

struct Module: public interface::Module, public main_context::Interface
{
	interface::Server *m_server;
	magic::SharedPtr<magic::Context> m_context;
	magic::SharedPtr<magic::Engine> m_engine;
	magic::SharedPtr<magic::Scene> m_scene;
	sm_<Event::Type, magic::SharedPtr<interface::MagicEventHandler>
			> m_magic_event_handlers;

	uint64_t profiler_last_print_us = 0;

	Module(interface::Server *server):
		interface::Module("main_context"),
		m_server(server),
		profiler_last_print_us(interface::os::get_timeofday_us())
	{
		log_d(MODULE, "main_context construct");
	}

	~Module()
	{
		log_d(MODULE, "main_context destruct");
	}

	void init()
	{
		log_d(MODULE, "main_context init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));

		// Initialize Urho3D

		m_context = new magic::Context();
		m_engine = new magic::Engine(m_context);

		// Disable timestamps in Urho3D log message events
		magic::Log *magic_log = m_context->GetSubsystem<magic::Log>();
		magic_log->SetTimeStamp(false);

		const interface::ServerConfig &server_config = m_server->get_config();

		sv_<ss_> resource_paths = {
			server_config.urho3d_path+"/Bin/CoreData",
			server_config.urho3d_path+"/Bin/Data",
		};
		auto *fs = interface::getGlobalFilesystem();
		ss_ resource_paths_s;
		for(const ss_ &path : resource_paths){
			if(!resource_paths_s.empty())
				resource_paths_s += ";";
			resource_paths_s += fs->get_absolute_path(path);
		}

		magic::VariantMap params;
		params["ResourcePaths"] = resource_paths_s.c_str();
		params["Headless"] = true;
		params["LogName"] = ""; // Don't log to file
		params["LogQuiet"] = true; // Don't log to stdout
		if(!m_engine->Initialize(params))
			throw Exception("Urho3D engine initialization failed");

		m_scene = new magic::Scene(m_context);

		auto *physics = m_scene->CreateComponent<magic::PhysicsWorld>(
				magic::LOCAL);
		physics->SetFps(30);
		physics->SetInterpolation(false);

		// Useless but gets rid of warnings like
		// "ERROR: No Octree component in scene, drawable will not render"
		m_scene->CreateComponent<magic::Octree>(magic::LOCAL);

		magic::ResourceCache *magic_cache =
				m_context->GetSubsystem<magic::ResourceCache>();
		//magic_cache->SetAutoReloadResources(true);
		magic_cache->SetResourceRouter(
				new BuildatResourceRouter(m_context, m_server));

		sub_magic_event(magic::E_LOGMESSAGE,
				Event::t("urho3d_log_redirect:message"));
		m_server->sub_event(this, Event::t("urho3d_log_redirect:message"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("urho3d_log_redirect:message", on_message,
				interface::MagicEvent)
	}

	void on_start()
	{
		log_v(MODULE, "main_context start");
	}

	void on_unload()
	{
		log_v(MODULE, "main_context unload");
	}

	void on_continue()
	{
		log_v(MODULE, "main_context continue");
	}

	void on_tick(const interface::TickEvent &event)
	{
		m_engine->SetNextTimeStep(event.dtime);
		m_engine->RunFrame();

		uint64_t current_us = interface::os::get_timeofday_us();
		magic::Profiler *p = m_context->GetSubsystem<magic::Profiler>();
		if(p && profiler_last_print_us < current_us - 10000000){
			profiler_last_print_us = current_us;
			magic::String s = p->GetData(false, false, UINT_MAX);
			p->BeginInterval();
			log_v(MODULE, "Urho3D profiler:\n%s", s.CString());
		}
	}

	void on_message(const interface::MagicEvent &event)
	{
		int magic_level = event.magic_data.Find("Level")->second_.GetInt();
		ss_ message = event.magic_data.Find("Message")->second_.
				GetString().CString();
		int core_level = LOG_ERROR;
		if(magic_level == magic::LOG_DEBUG)
			core_level = LOG_DEBUG;
		else if(magic_level == magic::LOG_INFO)
			core_level = LOG_VERBOSE;
		else if(magic_level == magic::LOG_WARNING)
			core_level = LOG_WARNING;
		else if(magic_level == magic::LOG_ERROR)
			core_level = LOG_ERROR;
		log_(core_level, MODULE, "Urho3D %s", cs(message));
	}

	// Interface

	magic::Context* get_context()
	{
		return m_context;
	}

	magic::Scene* get_scene()
	{
		return m_scene;
	}

	void sub_magic_event(
			const magic::StringHash &event_type,
			const Event::Type &buildat_event_type)
	{
		m_magic_event_handlers[buildat_event_type] =
				new interface::MagicEventHandler(
				m_context, m_server, event_type, buildat_event_type);
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main_context(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
