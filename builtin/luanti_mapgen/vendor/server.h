// A shim, not Luanti's: see README.txt.
//
// Two managers ask a Server for its EmergeManager so that they can clear
// dangling references when the game is unloaded. Nothing here is ever
// unloaded that way -- the managers live as long as the world does -- so
// this is the smallest thing that lets those two compile: a Server that
// has no EmergeManager.
#pragma once

class EmergeManager;

class Server
{
public:
	EmergeManager* getEmergeManager(){ return nullptr; }
};
