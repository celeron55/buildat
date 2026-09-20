// A shim, not Luanti's: see README.txt.
//
// Luanti's EmergeManager is the threads and the queue that decide when a
// block is generated; worldgen is that here, so what is left of this is
// EmergeParams -- the bundle of managers a Mapgen is constructed with.
//
// It is a plain struct here rather than something an EmergeManager hands
// out, because this module builds one itself out of what builtin/luanti
// sent over.
#ifndef LUANTI_SHIM_EMERGE_H
#define LUANTI_SHIM_EMERGE_H
#include "irrlichttypes_bloated.h"
#include "mapgen.h"
#include "map.h"
#include "util/container.h"
#include "util/basic_macros.h"
#include <set>
#include <string>

class NodeDefManager;
class BiomeGen;
class BiomeManager;
class OreManager;
class DecorationManager;
class SchematicManager;
class EmergeManager;

// What a mapgen is handed for one chunk: the manipulator to write into,
// where it is and what seed it is a function of. Luanti's own, and the
// module fills one in before it calls makeChunk().
struct BlockMakeData {
	MMVManip *vmanip = nullptr;
	u64 seed = 0;
	v3s16 blockpos_min;
	v3s16 blockpos_max;
	UniqueQueue<v3s16> transforming_liquid;
	const NodeDefManager *nodedef = nullptr;

	BlockMakeData() = default;
	~BlockMakeData(){ delete vmanip; }
};

class EmergeParams
{
public:
	EmergeParams() = default;
	// What Luanti's own destructor does: an EmergeParams is made per mapgen
	// out of clones of the managers, and it deletes them. The Mapgen
	// deletes the EmergeParams, so this is the end of the chain.
	~EmergeParams()
	{
		delete biomegen;
		delete biomemgr;
		delete oremgr;
		delete decomgr;
		delete schemmgr;
	}
	DISABLE_CLASS_COPY(EmergeParams);

	const NodeDefManager *ndef = nullptr;
	bool enable_mapgen_debug_info = false;

	u32 gen_notify_on = 0;
	// Empty rather than null: the notifier keeps the pointers and reads
	// through them
	std::set<u32> m_no_deco_ids;
	std::set<std::string> m_no_custom;
	const std::set<u32> *gen_notify_on_deco_ids = &m_no_deco_ids;
	const std::set<std::string> *gen_notify_on_custom = &m_no_custom;

	BiomeGen *biomegen = nullptr;
	BiomeManager *biomemgr = nullptr;
	OreManager *oremgr = nullptr;
	DecorationManager *decomgr = nullptr;
	SchematicManager *schemmgr = nullptr;

	inline GenerateNotifier createNotifier() const {
		return GenerateNotifier(gen_notify_on, gen_notify_on_deco_ids,
				gen_notify_on_custom);
	}
};

// Luanti's EmergeManager is the queue and the threads that decide when a
// block is generated, which worldgen is here. The two managers that ask a
// Server for one only use it to clear references at shutdown; this is
// enough for them to compile and answers that there is none.
class DecorationManager;

class EmergeManager
{
public:
	DecorationManager* getWritableDecorationManager(){ return nullptr; }
	BiomeManager* getWritableBiomeManager(){ return nullptr; }
	OreManager* getWritableOreManager(){ return nullptr; }
	SchematicManager* getWritableSchematicManager(){ return nullptr; }
};

#endif
