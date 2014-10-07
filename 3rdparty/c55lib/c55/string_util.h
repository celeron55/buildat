// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include <string>
#include <stdio.h>

namespace c55
{
	class Strfnd {
		std::string tek;
		unsigned int p;
	public:
		void start(std::string niinq){
			tek = niinq;
			p = 0;
		}
		unsigned int where(){
			return p;
		}
		void to(unsigned int i){
			p = i;
		}
		std::string what(){
			return tek;
		}
		// Returns true if search_for was found
		bool next(const std::string &search_for, std::string &result){
			if(p >= tek.size())
				return false;
			size_t n = tek.find(search_for, p);
			bool did_find = (n != std::string::npos);
			if(n == std::string::npos || search_for == "")
				n = tek.size();
			result = tek.substr(p, n - p);
			p = n + search_for.length();
			return did_find;
		}
		std::string next(const std::string &search_for){
			std::string result;
			next(search_for, result);
			return result;
		}
		std::string while_any(const std::string &chars){
			if(chars.empty())
				return std::string();
			if(p >= tek.size())
				return std::string();
			size_t n = p;
			while(n < tek.size()){
				bool is = false;
				for(unsigned int i = 0; i < chars.size(); i++){
					if(chars[i] == tek[n]){
						is = true;
						break;
					}
				}
				if(!is) break;
				n++;
			}
			std::string result = tek.substr(p, n - p);
			p = n;
			return result;
		}
		bool atend(){
			if(p >= tek.size()) return true;
			return false;
		}
		Strfnd(std::string s){
			start(s);
		}
	};

	inline std::string trim(std::string str,
			const std::string &whitespace = " \t\n\r")
	{
		size_t endpos = str.find_last_not_of(whitespace);
		if(std::string::npos != endpos)
			str = str.substr(0, endpos + 1);
		size_t startpos = str.find_first_not_of(whitespace);
		if(std::string::npos != startpos)
			str = str.substr(startpos);
		return str;
	}

	inline std::string vector_join(const std::vector<std::string> &v,
			const std::string &d = ", ")
	{
		std::string result;
		for(auto v1 : v)
			result += (result.empty() ? "" : d) + v1;
		return result;
	}

	inline std::string truncate_string(const std::string &str, size_t maxlen,
			const std::string &end = "...")
	{
		if(str.size() < maxlen)
			return str;
		return str.substr(0, maxlen) + end;
	}

	inline bool string_allowed(const std::string &s,
			const std::string &allowed_chars)
	{
		for(size_t i = 0; i < s.size(); i++){
			bool confirmed = false;
			for(size_t j = 0; j < allowed_chars.size(); j++){
				if(s[i] == allowed_chars[j]){
					confirmed = true;
					break;
				}
			}
			if(confirmed == false)
				return false;
		}
		return true;
	}
}
// vim: set noet ts=4 sw=4:
