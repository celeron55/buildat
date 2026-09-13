// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "storage/api.h"
#include <PolyVoxCore/Vector.h>
#include <PolyVoxCore/Region.h>
#include <PolyVoxCore/RawVolume.h>
#include <functional>

namespace Urho3D
{
	class Context;
	class Scene;
	class Node;
}

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace voxelworld
{
	namespace magic = Urho3D;
	namespace pv = PolyVox;

	using interface::VoxelVolume;
	using interface::VoxelInstance;
	using main_context::SceneReference;

	struct GenerationRequest: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		GenerationRequest(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene),
			section_p(section_p)
		{}
	};

	// A section has come into the world, or is about to leave it. What
	// listens is a game that keeps something of its own per section -- what
	// hangs off the nodes, the timers running in it -- and has to bring it
	// back with the section and write it out with it.
	//
	// Loaded is emitted after the voxels are there and unloaded before they
	// go; both reach the listener after voxelworld has let go of the
	// section, so a listener may call back into it.
	struct SectionLoaded: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		SectionLoaded(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene), section_p(section_p){}
	};

	struct SectionUnloaded: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		SectionUnloaded(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene), section_p(section_p){}
	};

	struct NodeVolumeUpdated: public interface::Event::Private
	{
		SceneReference scene;
		uint node_id;
		bool is_static_chunk = false;
		pv::Vector3DInt32 chunk_p; // Only set if is_static_chunk == true

		NodeVolumeUpdated(SceneReference scene, uint node_id,
				bool is_static_chunk, const pv::Vector3DInt32 &chunk_p):
			scene(scene), node_id(node_id),
			is_static_chunk(is_static_chunk), chunk_p(chunk_p)
		{}
	};

	// Where the world is kept loaded: a point in voxels, and how far around
	// it sections live. The radii are per point because a player needs a big
	// one and a machine that only has to keep working needs the smallest one
	// that does -- and because two players differ from each other: a client
	// on a weaker computer wants less sent to it, and loading more than that
	// client will look at is the server spending memory on nothing.
	//
	// A section pinned in place is a point with every radius zero.
	struct LoadPoint
	{
		pv::Vector3DInt32 p; // In voxels
		// Sections this far out are loaded if the save has them and left
		// alone if it does not: what a player sees far away is the terrain
		// that is already there, and new terrain appears closer in. This is
		// also the radius a section has to leave before it is unloaded, so
		// keeping it larger than the generate radius is what stops a player
		// walking back and forth from generating the same section twice.
		int16_t load_xz = 0;
		int16_t load_y = 0;
		// ... and this far out, generated as well. <= the load radii.
		int16_t generate_xz = 0;
		int16_t generate_y = 0;
		// Whose point this is, if it is a client's, and zero if it is not.
		// A peer's point is also where the world is sent to that peer from:
		// how much it gets is the smaller of what its client asked for and
		// this point's load radius, because the server cannot send what it
		// does not keep. A peer with no point of its own gets everything.
		size_t peer = 0;

		LoadPoint(){}
		LoadPoint(const pv::Vector3DInt32 &p,
				int16_t load_xz, int16_t load_y,
				int16_t generate_xz, int16_t generate_y, size_t peer = 0):
			p(p), load_xz(load_xz), load_y(load_y),
			generate_xz(generate_xz), generate_y(generate_y), peer(peer)
		{}
	};

	struct Instance;

	struct CommitHook
	{
		virtual ~CommitHook(){}
		virtual void in_thread(voxelworld::Instance *world,
				const pv::Vector3DInt32 &chunk_p,
				VoxelVolume &volume){}
		virtual void in_scene(voxelworld::Instance *world,
				const pv::Vector3DInt32 &chunk_p, magic::Node *n){}
	};

	struct Instance
	{
		virtual interface::VoxelRegistry* get_voxel_reg() = 0;

		// Persist this world in a save, under a name of its own -- a save
		// holds zero, one or many worlds, so the name is what separates
		// them. Until this is called nothing is persisted, which is what
		// every game did before it existed: generate and forget.
		//
		// Call it after registering voxels and before asking for any
		// section. Sections already in the save are loaded instead of
		// generated.
		//
		// The running game owns the voxel numbering and the save stores
		// names: what a save holds is a name table, and loading translates
		// its ids into the ones this run registered. So a game is free to
		// register its types in another order, or to add and drop them,
		// without a world it has saved meaning anything else than it did.
		// Registering more types after this call is allowed; each reaches
		// the save's table before anything holding it is written.
		//
		// The Save belongs to whoever opened it, and closing it while a
		// world still points at it is a use-after-free. Pass nullptr to stop
		// persisting first.
		virtual void set_save(storage::Save *save, const ss_ &world_name) = 0;

		// Write out every section that has changed since it was read.
		// Happens by itself when a section is unloaded and at shutdown, so
		// this is for a game that wants a checkpoint of its own.
		virtual void save() = 0;

		// Voxel types the save holds that this game does not register. They
		// are kept, drawn with the definitions the save carries and tinted,
		// so an old world still looks like itself -- but the game no longer
		// supports them, and this is how a game says so on screen instead of
		// leaving someone to walk into it.
		virtual sv_<interface::VoxelName> get_unknown_voxels() = 0;

		virtual void add_commit_hook(up_<CommitHook> hook) = 0;

		virtual pv::Vector3DInt16 get_section_size_voxels() = 0;

		virtual pv::Region get_section_region_voxels(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual const pv::Vector3DInt16& get_chunk_size_voxels() = 0;

		virtual pv::Region get_chunk_region_voxels(
				const pv::Vector3DInt32 &chunk_p) = 0;

		virtual void load_or_generate_section(
				const pv::Vector3DInt16 &section_p) = 0;

		// The points the world stays loaded around, replacing the previous
		// set; call it whenever they move, it only remembers them. A few
		// sections are loaded, generated or unloaded per pass after that, so
		// that one tick never carries a whole world.
		//
		// Nothing outside the region given to create_instance() is loaded,
		// which is what makes that region the world's bounds: a game that
		// streams says how tall and how wide its world is by asking for it,
		// and the sky is still at the top of it.
		//
		// A world that never calls this loads its whole region at the start
		// and keeps it, which is what every game did before this existed.
		virtual void set_load_points(const sv_<LoadPoint> &points) = 0;

		// Every section that is loaded right now, in no particular order.
		// What asks is a sweep -- an ABM, a fill, an importer clipping what
		// it reads -- which would otherwise walk the bounds and skip what is
		// not there; over a streamed world that walk is the cost.
		virtual sv_<pv::Vector3DInt16> get_loaded_sections() = 0;

		// How many sections one streaming pass may load, generate or unload;
		// two by default. A game whose generator runs behind turns this down
		// to nothing while its queue is long and back up when it drains --
		// only the game can see that queue. Nothing else should touch it.
		virtual void set_stream_budget(size_t sections_per_pass) = 0;

		virtual void unload_section(const pv::Vector3DInt16 &section_p) = 0;

		virtual bool is_section_loaded(const pv::Vector3DInt16 &section_p) = 0;

		virtual void set_voxel(const pv::Vector3DInt32 &p,
				const VoxelInstance &v,
				bool disable_warnings = false) = 0;

		// The voxels of a region, in one read rather than one per voxel:
		// what asks for this is a sweep, and a section is a quarter of a
		// million voxels. The answer carries every plane the chunks it came
		// from have.
		//
		// What is not there -- a section that is not loaded, a chunk nothing
		// has written -- comes back as VOXELTYPEID_UNDEFINED, which is what
		// get_voxel() answers for one.
		virtual VoxelVolume get_volume(const pv::Region &region) = 0;

		// The other direction, and the one merge_volume() below is not:
		// every defined voxel of the volume is written, whatever was there.
		// An importer, a VoxelManip and a mod putting a building down all
		// mean this; a generator means merge_volume().
		//
		// A voxel that is undefined in the volume is skipped, so a caller
		// can still leave holes, and create_missing_sections works the same
		// way it does below.
		virtual void set_volume(const VoxelVolume &volume,
				bool create_missing_sections = false) = 0;

		// Write a generated volume into the world, by priority per voxel: a
		// voxel that has not been generated yet (VOXELTYPEID_UNDEFINED) takes
		// anything, an empty one takes anything that is not empty, and one
		// that already holds something is left alone -- it is either terrain
		// that was generated by whoever owns that section or something that
		// was built there since, and neither should be overwritten by a
		// neighbour's padding. A voxel that is undefined in the volume is
		// skipped, so a generator can leave holes for others to fill.
		//
		// The volume may reach outside the section it was generated for.
		// With create_missing_sections, a section it reaches into that does
		// not exist yet is created and left ungenerated, holding only what
		// the volume puts in it; it is generated for real when someone asks
		// for it. Without it, such a part of the volume is dropped.
		//
		// "Empty" is VoxelDefinition::fully_empty: a voxel that nothing
		// occupies. A voxel that merely leaves the faces against it undrawn
		// (EDGEMATERIALID_EMPTY) may still hold a mesh of its own, and counts
		// as something standing there.
		virtual void merge_volume(
				const VoxelVolume &volume,
				bool create_missing_sections) = 0;

		// Maintain VoxelInstance::get_skylight() of every voxel in the world.
		// Off by default; a world that does not want skylight pays nothing and
		// keeps whatever is in those bits. Once on, the light is kept up to
		// date by set_voxel(), including through generation, and is settled
		// before commit() meshes anything.
		//
		// Light enters from above the top of the world region at full
		// strength, falls through anything that transmits light without
		// losing any, and spreads sideways and upwards losing one step per
		// voxel. A voxel transmits light if its edge material is
		// EDGEMATERIALID_EMPTY, which is the same test the mesher uses to
		// decide whether a face is drawn against it.
		//
		// simplified: transparency is that one test, so glass would have to
		// be a light barrier or a hole in the terrain. A voxel definition
		// flag of its own is the upgrade path.
		virtual void set_skylight_enabled(bool enabled) = 0;

		virtual size_t num_buffers_loaded() = 0;

		virtual void commit() = 0;

		virtual VoxelInstance get_voxel(const pv::Vector3DInt32 &p,
				bool disable_warnings = false) = 0;

		// The same, for a world whose voxels are more than one plane: a
		// sample is every plane of a voxel read or written together. A
		// chunk takes on the world's planes the first time one is written
		// into it.
		//
		// set_voxel() writes the first plane and leaves the rest of a
		// voxel alone, which is what it has always meant and what a game
		// with one plane wants; set_sample() writes all of them.
		virtual void set_sample(const pv::Vector3DInt32 &p,
				const interface::VoxelSample &v,
				bool disable_warnings = false) = 0;
		virtual interface::VoxelSample get_sample(const pv::Vector3DInt32 &p,
				bool disable_warnings = false) = 0;

		// NOTE: There is no interface in here for directly accessing chunk
		// volumes of static nodes, because it is so much more hassly and was
		// tested to improve speed only by 53% compared to the current very
		// robust interface.
	};

	struct Interface
	{
		// physics_enabled gives the chunk nodes server-side Bullet collision
		// shapes. Off by default: they cost more than the world generation
		// they are built alongside, and only a game that has the server
		// simulate something against the terrain queries them at all. A game
		// that reads terrain hits out of the voxel volumes does not need them.
		// It is a parameter and not a setting because the initial sections are
		// created here. The client has its own switch; see physics_distance in
		// voxelworld's client_lua.
		//
		// The region is in sections, and is the world's bounds: nothing
		// outside it is ever loaded, and the sky is above the top of it. A
		// world that does not stream (see set_load_points()) also has every
		// section of it loaded at the start, so a world that wants bounds
		// bigger than it wants to load has to stream.
		virtual void create_instance(SceneReference scene_ref,
				const pv::Region &region, bool physics_enabled = false) = 0;
		virtual void delete_instance(SceneReference scene_ref) = 0;

		virtual Instance* get_instance(SceneReference scene_ref) = 0;

		virtual void commit() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(voxelworld::Interface*)> cb)
	{
		return server->access_module("voxelworld", [&](interface::Module *module){
			auto *iface = (voxelworld::Interface*)module->check_interface();
			cb(iface);
			iface->commit();
		});
	}

	inline bool access(interface::Server *server, SceneReference scene_ref,
			std::function<void(voxelworld::Instance*instance)> cb)
	{
		return access(server, [&](voxelworld::Interface *i){
			voxelworld::Instance *instance =
					check(i->get_instance(scene_ref));
			cb(instance);
		});
	}
}

// vim: set noet ts=4 sw=4:
