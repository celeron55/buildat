// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/voxel.h"
#include <PolyVoxCore/Vector.h>
#include <PolyVoxCore/Region.h>
#include <functional>

namespace Urho3D
{
	class Context;
	class Scene;
}

namespace voxelworld
{
	namespace magic = Urho3D;
	namespace pv = PolyVox;

	struct GenerationRequest: public interface::Event::Private
	{
		pv::Vector3DInt16 section_p;

		GenerationRequest(const pv::Vector3DInt16 &section_p):
				section_p(section_p)
		{}
	};

	struct Interface
	{
		virtual void load_or_generate_section(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual pv::Region get_section_region(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual void set_voxel(const pv::Vector3DInt32 &p,
				const interface::VoxelInstance &v) = 0;

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
}

// vim: set noet ts=4 sw=4:
