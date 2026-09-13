// A shim, not Luanti's: see README.txt.
#include "nodedef.h"
#include "log.h"

NodeDefManager::NodeDefManager()
{
	m_unknown.name = "unknown";
	m_unknown.drawtype = NDT_NORMAL;
	m_unknown.walkable = true;
}

void NodeDefManager::set_content(const std::string &name, content_t id,
		const ContentFeatures &f)
{
	m_id_of_name[name] = id;
	if(m_features.size() <= (size_t)id)
		m_features.resize((size_t)id + 1);
	m_features[id] = f;
}

content_t NodeDefManager::getId(const std::string &name) const
{
	auto it = m_id_of_name.find(name);
	if(it == m_id_of_name.end())
		return CONTENT_IGNORE;
	return it->second;
}

bool NodeDefManager::getId(const std::string &name, content_t &result) const
{
	content_t c = getId(name);
	if(c == CONTENT_IGNORE)
		return false;
	result = c;
	return true;
}

bool NodeDefManager::getIds(const std::string &name,
		std::vector<content_t> &result) const
{
	// simplified: a group is not known on this side of the boundary, so
	// "group:..." matches nothing. What asks is an ore or a decoration
	// naming a group of nodes to be placed in; the upgrade path is to send
	// the groups over with the ids.
	if(name.compare(0, 6, "group:") == 0)
		return false;
	content_t c = getId(name);
	if(c == CONTENT_IGNORE)
		return false;
	result.push_back(c);
	return true;
}

const ContentFeatures& NodeDefManager::get(content_t c) const
{
	if((size_t)c < m_features.size())
		return m_features[c];
	return m_unknown;
}

void NodeDefManager::pendNodeResolve(NodeResolver *nr) const
{
	// The definitions are all here already, so there is nothing to wait for
	nr->m_ndef = this;
	nr->nodeResolveInternal();
}

void NodeResolver::nodeResolveInternal()
{
	m_nodenames_idx = 0;
	m_nnlistsizes_idx = 0;
	resolveNodeNames();
	m_resolve_done = true;
	m_nodenames.clear();
	m_nnlistsizes.clear();
}

bool NodeResolver::getIdFromNrBacklog(content_t *result_out,
		const std::string &node_alt, content_t c_fallback,
		bool error_on_fallback)
{
	if(m_nodenames_idx == m_nodenames.size()){
		*result_out = c_fallback;
		return false;
	}
	std::string name = m_nodenames[m_nodenames_idx++];
	content_t c = m_ndef->getId(name);
	if(c == CONTENT_IGNORE && !node_alt.empty()){
		name = node_alt;
		c = m_ndef->getId(name);
	}
	if(c == CONTENT_IGNORE){
		if(error_on_fallback){
			warningstream<<"NodeResolver: no node called \""<<name
					<<"\"; using a fallback"<<std::endl;
		}
		c = c_fallback;
		*result_out = c;
		return false;
	}
	*result_out = c;
	return true;
}

bool NodeResolver::getIdsFromNrBacklog(std::vector<content_t> *result_out,
		bool all_required, content_t c_fallback)
{
	if(m_nnlistsizes_idx == m_nnlistsizes.size()){
		if(all_required)
			result_out->push_back(c_fallback);
		return false;
	}
	size_t length = m_nnlistsizes[m_nnlistsizes_idx++];
	bool success = true;
	while(length--){
		if(m_nodenames_idx == m_nodenames.size()){
			if(all_required)
				result_out->push_back(c_fallback);
			return false;
		}
		const std::string &name = m_nodenames[m_nodenames_idx++];
		std::vector<content_t> idset;
		if(m_ndef->getIds(name, idset)){
			for(content_t c : idset)
				result_out->push_back(c);
		} else {
			warningstream<<"NodeResolver: no node called \""<<name<<"\""
					<<std::endl;
			if(all_required)
				result_out->push_back(c_fallback);
			success = false;
		}
	}
	return success;
}
