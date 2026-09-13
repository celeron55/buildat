// A shim, not Luanti's: see README.txt.
//
// Luanti's EmergeManager is the threads and the queue that decide when a
// block is generated; worldgen is that here, so what is left of this is
// EmergeParams -- the bundle of managers a Mapgen is constructed with.
//
// It is a plain struct here rather than something an EmergeManager hands
// out, because this module builds one itself out of what builtin/luanti
// sent over.
#pragma once
#include "irrlichttypes_bloated.h"
#include "mapgen.h"
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

class EmergeParams
{
public:
	EmergeParams() = default;
	~EmergeParams() = default;
	DISABLE_CLASS_COPY(EmergeParams);

	const NodeDefManager *ndef = nullptr;
	bool enable_mapgen_debug_info = false;

	u32 gen_notify_on = 0;
	const std::set<u32> *gen_notify_on_deco_ids = nullptr;
	const std::set<std::string> *gen_notify_on_custom = nullptr;

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
