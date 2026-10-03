// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_1] phase 4: a section's voxels as a server sends them and a
// save holds them (interface/voxel_volume.h deserialize_volume).
#include "interface/voxel_volume.h"
#include <stdexcept>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const ss_ in((const char*)data, size);
	try {
		auto v = interface::deserialize_volume(in);
		if(v){
			const auto r = v->getEnclosingRegion();
			v->getVoxelAt(r.getLowerCorner().getX(),
					r.getLowerCorner().getY(), r.getLowerCorner().getZ());
		}
	} catch(std::exception &e){
	}
	try { interface::deserialize_volume_int32(in); } catch(std::exception &e){}
	try { interface::deserialize_volume_8bit(in); } catch(std::exception &e){}
	return 0;
}
