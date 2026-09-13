// A shim, not Luanti's: see README.txt.
//
// Luanti's IGameDef is the server or the client behind an interface; the
// mapgen only ever asks it for the node definitions, and here it is handed
// those directly.
#ifndef LUANTI_SHIM_GAMEDEF_H
#define LUANTI_SHIM_GAMEDEF_H
#include "nodedef.h"

class IGameDef
{
public:
	virtual ~IGameDef(){}
	virtual const NodeDefManager* getNodeDefManager() = 0;
};

#endif
