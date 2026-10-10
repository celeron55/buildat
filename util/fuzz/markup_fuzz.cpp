// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_2]: Hearth's markup (interface/markup.h over md4c), what
// any account's message is turned into for the HTML face. Beside the
// sanitizers, an oracle of its own: the page gets only the tags and
// attributes the renderer writes, and no href with a scheme past http,
// https and mailto, and no image but the Hearth's own /f/<id>[/<name>] -- read here
// independently of markup.cpp's own check.
#include "interface/markup.h"
#include <cstring>
#include <cctype>
#include <regex>
#include <set>
#include <cstdlib>

static const std::set<ss_> TAGS = {"p", "em", "strong", "a", "code", "del",
	"span", "pre", "blockquote", "ul", "ol", "li", "hr", "h1", "h2", "h3",
	"h4", "h5", "h6", "table", "thead", "tbody", "tr", "th", "td", "br",
	"input", "img"};
static const std::set<ss_> ATTRS = {"href", "title", "rel", "class",
	"tabindex", "start", "style", "type", "disabled", "checked", "src",
	"alt", "loading"};

// One pass, as a browser decodes an attribute: the five the renderer
// writes, numeric references, and any other named one taken as ':' --
// the worst it could be (&colon; is one)
static ss_ unescape(const ss_ &v)
{
	ss_ r;
	for(size_t i = 0; i < v.size(); i++){
		size_t semi = v.find(';', i);
		if(v[i] != '&' || semi == ss_::npos || semi - i > 32){
			r += v[i];
			continue;
		}
		ss_ name = v.substr(i + 1, semi - i - 1);
		bool word = !name.empty();
		for(char c : name)
			word = word && (isalnum((unsigned char)c) || c == '#');
		if(!word){
			r += v[i];
			continue;
		}
		if(name == "amp") r += '&';
		else if(name == "lt") r += '<';
		else if(name == "gt") r += '>';
		else if(name == "quot") r += '"';
		else if(name[0] == '#'){
			bool hex = name.size() > 1 && (name[1] == 'x' || name[1] == 'X');
			long c = strtol(name.c_str() + (hex ? 2 : 1), nullptr, hex ? 16 : 10);
			r += c > 0 && c < 128 ? (char)c : '?';
		}
		else r += ':';
		i = semi;
	}
	return r;
}

static bool scheme_ok(const ss_ &href)
{
	ss_ s;
	for(char c : unescape(href))
		if((unsigned char)c > ' ')
			s += (char)tolower((unsigned char)c);
	size_t colon = s.find(':');
	if(colon == ss_::npos || s.find_first_of("/?#") < colon)
		return true;
	ss_ sc = s.substr(0, colon);
	return sc == "http" || sc == "https" || sc == "mailto";
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const ss_ out = interface::markup::to_html(ss_((const char*)data, size));
	for(size_t i = out.find('<'); i != ss_::npos; i = out.find('<', i + 1)){
		size_t j = i + 1 + (out[i + 1] == '/');
		size_t e = out.find_first_of(" >", j);
		if(e == ss_::npos || !TAGS.count(out.substr(j, e - j)))
			__builtin_trap();
		size_t close = out.find('>', e);
		if(close == ss_::npos)
			__builtin_trap();
		// Attributes: name or name="value", the value holding no quote
		size_t k = e;
		while(k < close){
			while(k < close && out[k] == ' ')
				k++;
			if(k >= close)
				break;
			size_t ne = out.find_first_of("= >", k);
			ss_ name = out.substr(k, ne - k);
			if(!ATTRS.count(name))
				__builtin_trap();
			k = ne;
			if(out[k] == '='){
				if(out[k + 1] != '"')
					__builtin_trap();
				size_t ve = out.find('"', k + 2);
				if(ve == ss_::npos || ve > close)
					__builtin_trap();
				if(name == "href" && !scheme_ok(out.substr(k + 2, ve - k - 2)))
					__builtin_trap();
				// An image is the Hearth's own file and nothing else
				// ([HEARTH_ATTACHMENTS]), by exactly its path
				// ([SEC_RUN4_LEFTOVERS])
				static const std::regex own("/f/[0-9]+(/[^/?#]*)?");
				const ss_ v = unescape(out.substr(k + 2, ve - k - 2));
				if(name == "src" && !std::regex_match(v, own))
					__builtin_trap();
				k = ve + 1;
			}
		}
		i = close;
	}
	return 0;
}
