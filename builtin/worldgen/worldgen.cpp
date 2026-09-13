#include "core/log.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/noise.h"
#include "interface/voxel_volume.h"
#include "interface/thread.h"
#include "interface/semaphore.h"
#include "interface/os.h"
#include <Vector2.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <deque>
#define MODULE "worldgen"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;

// TODO: Move to a header (core/types_polyvox.h or something)
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

// TODO: Move to a header (core/cereal_polyvox.h or something)
namespace cereal {

template<class Archive>
void save(Archive &archive, const pv::Vector3DInt32 &v){
	archive((int32_t)v.getX(), (int32_t)v.getY(), (int32_t)v.getZ());
}
template<class Archive>
void load(Archive &archive, pv::Vector3DInt32 &v){
	int32_t x, y, z;
	archive(x, y, z);
	v.setX(x); v.setY(y); v.setZ(z);
}

}

namespace worldgen {

struct Module;

struct GenerateThread: public interface::ThreadedThing
{
	Module *m_module = nullptr;

	GenerateThread(Module *module):
		m_module(module)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

// One section of one instance: what has to be known before generating it
struct GenerateTask
{
	SceneReference scene_ref;
	pv::Vector3DInt16 section_p = pv::Vector3DInt16(0, 0, 0);
	GeneratorInterface *generator = nullptr;
};

struct CInstance: public worldgen::Instance
{
	interface::Server *m_server;
	SceneReference m_scene_ref;

	up_<GeneratorInterface> m_generator;
	bool m_enabled = false;

	std::deque<pv::Vector3DInt16> m_queued_sections;

	CInstance(interface::Server *server, SceneReference scene_ref):
		m_server(server),
		m_scene_ref(scene_ref)
	{}

	~CInstance()
	{}

	void on_generation_request(const pv::Vector3DInt16 &section_p)
	{
		m_queued_sections.push_back(section_p);
		log_v(MODULE, "Queued section (%i, %i, %i); queue size: %zu (scene %p)",
				section_p.getX(), section_p.getY(),
				section_p.getZ(), m_queued_sections.size(), m_scene_ref);
		m_server->emit_event("worldgen:queue_modified",
				new QueueModifiedEvent(m_scene_ref, m_queued_sections.size()));
	}

	// Interface for GenerateThread

	// NOTE: on_tick() cannot be used here, because as this takes much longer
	//       than a tick, the ticks accumulate and result in nothing getting
	//       queued but instead sectors get queued in the event queue.

	// Take one section off the queue. Called with the module held; the
	// generation itself is done outside it.
	bool take_next_section(pv::Vector3DInt16 *section_p_out,
			GeneratorInterface **generator_out)
	{
		if(!m_enabled || m_queued_sections.empty())
			return false;
		*section_p_out = m_queued_sections.front();
		*generator_out = m_generator.get();
		m_queued_sections.pop_front();
		return true;
	}

	void announce_queue_size()
	{
		m_server->emit_event("worldgen:queue_modified",
				new QueueModifiedEvent(m_scene_ref, m_queued_sections.size()));
	}

	// Interface

	void set_generator(GeneratorInterface *generator)
	{
		m_generator.reset(generator);
	}

	void enable()
	{
		m_enabled = true;
	}

	size_t get_num_sections_queued()
	{
		return m_queued_sections.size();
	}
};

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;

	sm_<SceneReference, up_<CInstance>> m_instances;
	sp_<interface::Thread> m_thread;
	interface::Semaphore m_queued_sections_sem;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		m_thread.reset(interface::createThread(new GenerateThread(this)));
		m_thread->set_name("worldgen/generate");
		m_thread->start();
	}

	~Module()
	{
		m_thread->request_stop();
		m_queued_sections_sem.post();
		m_thread->join();
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("voxelworld:generation_request"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("voxelworld:generation_request",
				on_generation_request, voxelworld::GenerationRequest)
	}

	void on_start()
	{
	}

	void on_continue()
	{
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_generation_request(const voxelworld::GenerationRequest &event)
	{
		auto it = m_instances.find(event.scene);
		if(it == m_instances.end())
			return;
		up_<CInstance> &instance = it->second;
		instance->on_generation_request(event.section_p);
		m_queued_sections_sem.post();
	}

	// Interface

	void create_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		// TODO: Is an exception the best way to handle this?
		if(it != m_instances.end())
			throw Exception("create_instance(): Scene already has worldgen");

		up_<CInstance> instance(new CInstance(m_server, scene_ref));
		m_instances[scene_ref] = std::move(instance);
	}

	void delete_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			throw Exception("delete_instance(): Scene does not have worldgen");
		m_instances.erase(it);
	}

	Instance* get_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			return nullptr;
		return it->second.get();
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	// Interface for GenerateThread. Called with no module held.
	void generate_and_merge(const GenerateTask &task)
	{
		try {
			if(!task.generator)
				return;

			// The section grown by whatever the generator needs to place a
			// thing that crosses the section boundary
			pv::Region region;
			voxelworld::access(m_server, task.scene_ref,
					[&](voxelworld::Instance *world)
			{
				region = world->get_section_region_voxels(task.section_p);
			});
			pv::Vector3DInt32 pad = task.generator->get_padding_voxels();
			region.setLowerCorner(region.getLowerCorner() - pad);
			region.setUpperCorner(region.getUpperCorner() + pad);

			log_v(MODULE, "Generating section " PV3I_FORMAT " (scene %p)",
					PV3I_PARAMS(task.section_p), task.scene_ref);

			// Undefined is what a generator leaves where it puts nothing,
			// and it is what a volume starts as: every plane of a new one
			// reads as zero, which is VOXELTYPEID_UNDEFINED, without any of
			// them being allocated
			VoxelVolume volume(region);

			task.generator->generate(task.scene_ref, task.section_p, volume);

			// Only this part needs voxelworld. A section the padding reaches
			// into that does not exist yet is created ungenerated, so that it
			// keeps whatever crossed into it and is still generated later.
			voxelworld::access(m_server, task.scene_ref,
					[&](voxelworld::Instance *world)
			{
				world->merge_volume(volume, true);
			});

			// On the main thread, after the merge: what a game runs over
			// terrain that has just appeared goes here
			m_server->emit_event("worldgen:section_generated",
					new SectionGenerated(task.scene_ref, task.section_p));

			worldgen::access(m_server, task.scene_ref,
					[&](worldgen::Instance *instance)
			{
				((CInstance*)instance)->announce_queue_size();
			});
		} catch(NullptrCatch &e){
			// Something was probably deleted or unloaded
			log_v(MODULE, "NullptrCatch: %s", e.what());
		}
	}
};

void GenerateThread::run(interface::Thread *thread)
{
	for(;;){
		// Give some time for accumulating the section queues
		interface::os::sleep_us(5000);
		// Wait for some generation requests
		m_module->m_queued_sections_sem.wait();
		if(thread->stop_requested())
			break;

		// Take one section for each instance. We can avoid implementing our
		// own mutex locking in Module by using
		// interface::Server::access_module() instead of directly accessing it.
		sv_<GenerateTask> tasks;
		worldgen::access(m_module->m_server,
				[&](worldgen::Interface *iworldgen)
		{
			for(auto &pair: m_module->m_instances){
				up_<CInstance> &instance = pair.second;
				if(!instance->m_enabled){
					if(!instance->m_queued_sections.empty()){
						// Has to be checked later
						m_module->m_queued_sections_sem.post();
					}
					continue;
				}
				GenerateTask task;
				task.scene_ref = instance->m_scene_ref;
				if(instance->take_next_section(&task.section_p,
						&task.generator))
					tasks.push_back(task);
			}
		});

		// Generate outside of every module: this is the part that takes
		// milliseconds per section, and voxelworld is wanted by everything
		// else in the meantime -- an explosion waiting for it is an explosion
		// the player sees seconds after the bomb landed.
		for(const GenerateTask &task : tasks)
			m_module->generate_and_merge(task);
	}
}

void GenerateThread::on_crash(interface::Thread *thread)
{
	m_module->m_server->shutdown(1, "GenerateThread crashed");
}

extern "C" {
	BUILDAT_EXPORT void* createModule_worldgen(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
