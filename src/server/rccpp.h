#pragma once
#include "core/types.h"

// This is what you get when the RCCPP is not enabled
#if !defined(RCCPP_ENABLED) && !defined(RCCPP)
#define RUNTIME_EXPORT_CLASS(C)
#define RUNTIME_VIRTUAL
#endif

#if defined(RCCPP) || defined(RCCPP_ENABLED)
#define RCCPP_USE_SINGLETON_NEWING
#define RUNTIME_VIRTUAL virtual
#define CLASS_INTERNALS(C) public: constexpr static const char *NAME = #C;
#include <cstddef>

struct RCCPP_Interface;

typedef void *(*RCCPP_Constructor)();
typedef void (*RCCPP_Destructor)(void *component);
typedef void (*RCCPP_PlacementNew)(void *buffer, size_t size);
typedef RCCPP_Interface *(*RCCPP_GetInterface)();

struct RCCPP_Interface {
	RCCPP_Constructor constructor;
	RCCPP_Destructor destructor;
	RCCPP_PlacementNew placementnew;
	const char *classname;
	size_t original_size;
};
#endif

// This is what the runtime compiler exports for the library.
#if defined(RCCPP) && !defined(RCCPP_ENABLED)
#include <new>
#define EXPORT __attribute__ ((visibility ("default")))
#define RUNTIME_EXPORT_CLASS(C) \
extern "C" { \
	static void *rccpp_constructor() { return new C(); } \
	static void rccpp_destructor(void *c) { delete reinterpret_cast<C*>(c); } \
	static void rccpp_placementnew(void *buffer, size_t size) { new (buffer) C(*(C*)buffer); } \
	EXPORT RCCPP_Interface *rccpp_GetInterface() { \
		static RCCPP_Interface interface; \
		interface.constructor = &rccpp_constructor; \
		interface.destructor = &rccpp_destructor; \
		interface.placementnew  = &rccpp_placementnew; \
		interface.classname = #C; \
		interface.original_size = sizeof(C); \
		return &interface; \
	} \
}
#endif

// And this is what your normal compiler sees when you have actually enabled RCCPP.
#if !defined(RCCPP) && defined(RCCPP_ENABLED)

#define RCCPP_CONSTRUCTOR "rccpp_constructor" 
#define RCCPP_DESTRUCTOR "rccpp_destructor" 
#define RCCPP_PLACEMENT_NEW "rccpp_placement_new" 
#define RCCPP_MOVE "rccpp_move" 
#define RCCPP_CLASSNAME "rccpp_classname" 

#define RUNTIME_EXPORT_CLASS(C)
#define RUNTIME_VIRTUAL virtual

#include <vector>
#include <cassert>
#include <memory>
#include <string>
#include <unordered_map>
#include <algorithm>

struct RCCPP_Info {
	void *module;
	void *module_prev;
	RCCPP_Constructor constructor;
	RCCPP_Destructor destructor;
	RCCPP_PlacementNew placement_new;
	size_t size;
};

class RuntimeClassBase;

class RCCPP_Compiler {
public:
    RCCPP_Compiler();

    void build(const std::string &in_path, const std::string &out_path);
	
	template<typename T> T *construct() { return (T*)construct(T::NAME); }
	void *construct(const char *name);
	
#if defined(RCCPP_USE_SINGLETON_NEWING)
	static RCCPP_Compiler &instance() {
		static RCCPP_Compiler i;
		return i;
	}
#endif
	std::vector<std::string> include_directories;
	std::vector<std::string> library_directories;
private:

	std::unordered_map<std::string, RCCPP_Info> component_info_;
	std::unordered_map<std::string, std::vector<void*>> constructed_objects;

	std::vector<std::string> changed_classes_;
	bool compile(const std::string &in_path, const std::string &out_path);
};

#endif

#if defined(RCCPP_ENABLED)
#include <cstddef>
template<typename T>
class RuntimeClass {
public:
#ifdef RCCPP_USE_SINGLETON_NEWING
	void *operator new(size_t size) { return RCCPP_Compiler::instance().construct(T::NAME); }
#endif
};

#ifdef RCCPP_USE_SINGLETON_NEWING
#define RCCPP_Update() RCCPP_Compiler::instance().update();
#endif

#else
template<typename T> class RuntimeClass { };
#endif
