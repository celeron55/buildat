// A shim, not Luanti's: see README.txt.
//
// Of nodedef.h's 864 lines the mapgen uses two calls on the manager and
// eight fields of a definition, so this is those and nothing else. What
// fills it is builtin/luanti's own registry, handed over as node ids by
// name when a world is made; see luanti_mapgen/api.h.
//
// Vendoring the real one would bring itemdef.h, sound.h and tile.h with
// it, and tile.h is the client.
#pragma once
#include "irrlichttypes_bloated.h"
#include "mapnode.h"
#include <string>
#include <vector>
#include <unordered_map>
#include <set>

enum NodeDrawType {
	NDT_NORMAL,
	NDT_AIRLIKE,
	NDT_LIQUID,
	NDT_FLOWINGLIQUID,
	NDT_GLASSLIKE,
	NDT_ALLFACES,
	NDT_ALLFACES_OPTIONAL,
	NDT_TORCHLIKE,
	NDT_SIGNLIKE,
	NDT_PLANTLIKE,
	NDT_FENCELIKE,
	NDT_RAILLIKE,
	NDT_NODEBOX,
	NDT_GLASSLIKE_FRAMED,
	NDT_FIRELIKE,
	NDT_GLASSLIKE_FRAMED_OPTIONAL,
	NDT_MESH,
	NDT_PLANTLIKE_ROOTED,
};

enum ContentParamType { CPT_NONE, CPT_LIGHT };

enum ContentParamType2 {
	CPT2_NONE,
	CPT2_FULL,
	CPT2_FLOWINGLIQUID,
	CPT2_FACEDIR,
	CPT2_WALLMOUNTED,
	CPT2_LEVELED,
	CPT2_DEGROTATE,
	CPT2_MESHOPTIONS,
	CPT2_COLOR,
	CPT2_COLORED_FACEDIR,
	CPT2_COLORED_WALLMOUNTED,
	CPT2_GLASSLIKE_LIQUID_LEVEL,
	CPT2_COLORED_DEGROTATE,
	CPT2_4DIR,
	CPT2_COLORED_4DIR,
};

enum LiquidType { LIQUID_NONE, LIQUID_FLOWING, LIQUID_SOURCE };

// What a mapgen asks about a node. Everything here is answered from the
// game's own definitions; what is not here is not asked.
struct ContentFeatures
{
	std::string name = "ignore";
	NodeDrawType drawtype = NDT_NORMAL;
	ContentParamType param_type = CPT_NONE;
	ContentParamType2 param_type_2 = CPT2_NONE;
	LiquidType liquid_type = LIQUID_NONE;
	bool walkable = true;
	bool is_ground_content = false;
	bool floodable = false;
	bool light_propagates = false;
	bool sunlight_propagates = false;
	u8 light_source = 0;

	bool isLiquid() const { return liquid_type != LIQUID_NONE; }

	ContentLightingFlags getLightingFlags() const {
		ContentLightingFlags f;
		f.has_light = (param_type == CPT_LIGHT);
		f.light_source = light_source;
		f.light_propagates = light_propagates;
		f.sunlight_propagates = sunlight_propagates;
		return f;
	}
};

// A resolver waits for the ids it asked about. The game's registry is
// frozen before any of this exists, so nothing waits: pendNodeResolve()
// resolves there and then, which is what Luanti's does once the definitions
// have been read.
class NodeDefManager;

class NodeResolver
{
public:
	virtual ~NodeResolver(){}
	virtual void resolveNodeNames() = 0;

	void nodeResolveInternal();

	bool getIdFromNrBacklog(content_t *result_out,
			const std::string &node_alt, content_t c_fallback,
			bool error_on_fallback = true);
	bool getIdsFromNrBacklog(std::vector<content_t> *result_out,
			bool all_required = false, content_t c_fallback = CONTENT_IGNORE);

	const NodeDefManager *m_ndef = nullptr;
	std::vector<std::string> m_nodenames;
	std::vector<size_t> m_nnlistsizes;
	size_t m_nodenames_idx = 0;
	size_t m_nnlistsizes_idx = 0;
	bool m_resolve_done = false;
};

class NodeDefManager
{
public:
	NodeDefManager();

	// The name a game gave a node, or an alias for it, to the id it got.
	// CONTENT_IGNORE for a name this game does not have, which is what
	// Luanti answers too.
	content_t getId(const std::string &name) const;
	bool getId(const std::string &name, content_t &result) const;

	// Every id whose name matches, for "group:..." and for a plain name.
	// A group is not known here, so only a plain name matches.
	bool getIds(const std::string &name, std::vector<content_t> &result) const;

	const ContentFeatures& get(content_t c) const;
	const ContentFeatures& get(const MapNode &n) const { return get(n.getContent()); }

	ContentLightingFlags getLightingFlags(content_t c) const {
		return get(c).getLightingFlags();
	}
	ContentLightingFlags getLightingFlags(const MapNode &n) const {
		return getLightingFlags(n.getContent());
	}

	// A resolver with the definitions already in place is a resolver that
	// runs now
	void pendNodeResolve(NodeResolver *nr) const;
	bool cancelNodeResolveCallback(NodeResolver *nr) const { return false; }

	// What builtin/luanti hands over: the ids by name, and the few
	// properties a mapgen asks about, by id
	void set_content(const std::string &name, content_t id,
			const ContentFeatures &f);

private:
	std::unordered_map<std::string, content_t> m_id_of_name;
	std::vector<ContentFeatures> m_features;
	ContentFeatures m_unknown;
};
