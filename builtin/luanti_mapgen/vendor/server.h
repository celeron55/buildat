// A shim, not Luanti's: see README.txt.
//
// The managers take a Server where the mapgen takes an IGameDef, and what
// either is asked for is the node definitions. A Server here is that and an
// EmergeManager that is nobody: the two managers only ask for one so that
// they can clear dangling references when a game is unloaded, and nothing
// here is unloaded that way -- the managers live as long as the world.
#ifndef LUANTI_SHIM_SERVER_H
#define LUANTI_SHIM_SERVER_H
#include "gamedef.h"
#include "nodedef.h"

class EmergeManager;

class Server: public IGameDef
{
public:
	Server(const NodeDefManager *ndef = nullptr): m_ndef(ndef){}
	EmergeManager* getEmergeManager(){ return nullptr; }
	const NodeDefManager* getNodeDefManager() override { return m_ndef; }
private:
	const NodeDefManager *m_ndef = nullptr;
};

#endif
