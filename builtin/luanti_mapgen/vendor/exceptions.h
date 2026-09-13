// A shim, not Luanti's: see README.txt.
#pragma once
#include <exception>
#include <string>

class BaseException: public std::exception
{
public:
	BaseException(const std::string &s) throw(): m_s(s){}
	~BaseException() throw(){}
	virtual const char* what() const throw(){ return m_s.c_str(); }
protected:
	std::string m_s;
};

#define LUANTI_SHIM_EXCEPTION(name) \
	class name: public BaseException { \
	public: name(const std::string &s): BaseException(s){} }

LUANTI_SHIM_EXCEPTION(InvalidPositionException);
LUANTI_SHIM_EXCEPTION(SerializationError);
LUANTI_SHIM_EXCEPTION(VersionMismatchException);
LUANTI_SHIM_EXCEPTION(SettingNotFoundException);
LUANTI_SHIM_EXCEPTION(ItemNotFoundException);
LUANTI_SHIM_EXCEPTION(ServerError);
LUANTI_SHIM_EXCEPTION(ModError);
