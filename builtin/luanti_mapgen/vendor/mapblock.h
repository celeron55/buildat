// A shim, not Luanti's: see README.txt.
//
// A MapBlock is Luanti's sixteen-cubed unit of map storage, which buildat
// has no equivalent of -- a chunk here is thirty-two and a section
// sixty-four. The mapgen only ever takes a pointer to one and hands it
// back, so the type is declared and nothing more.
#pragma once
#include "irrlichttypes_bloated.h"
#include "constants.h"
#include "mapnode.h"

class MapBlock;
