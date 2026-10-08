// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/markup.h"
#include "interface/web_brand.h"
#include <md4c.h>
#include <cctype>

namespace interface {
namespace markup {

static void escape(ss_ &r, const char *s, size_t n)
{
	r += web_brand::html(ss_(s, n));
}

// A destination a page may hold: http, https, mailto, or no scheme at all
// (relative). A browser skips leading spaces and controls and drops tabs
// and newlines inside a scheme ("java\tscript:"), so those are dropped
// here too before the scheme is read.
static bool safe_url(const ss_ &url)
{
	ss_ s;
	for(char c : url){
		if((unsigned char)c <= ' ' && (s.empty() || c == '\t' ||
				c == '\n' || c == '\r'))
			continue;
		s += (char)tolower((unsigned char)c);
	}
	size_t colon = s.find(':');
	if(colon == ss_::npos || s.find_first_of("/?#") < colon)
		return true;
	ss_ scheme = s.substr(0, colon);
	return scheme == "http" || scheme == "https" || scheme == "mailto";
}

struct Out {
	ss_ r;
	// Per open link or image: whether its <a> was written, so its close is
	// written or not
	sv_<bool> links;
};

static void open_link(Out *o, const MD_ATTRIBUTE &href,
		const MD_ATTRIBUTE &title)
{
	// The attribute's text as written: an entity in it stays its
	// characters, escaped below, so "java&#115;cript:" is a relative path
	// and never a scheme
	ss_ url(href.text, href.size);
	bool ok = safe_url(url);
	o->links.push_back(ok);
	if(!ok)
		return;
	o->r += "<a href=\"";
	escape(o->r, url.c_str(), url.size());
	o->r += "\"";
	if(title.size){
		o->r += " title=\"";
		escape(o->r, title.text, title.size);
		o->r += "\"";
	}
	o->r += " rel=\"nofollow ugc\">";
}

static int enter_block(MD_BLOCKTYPE t, void *d, void *u)
{
	Out *o = (Out*)u;
	switch(t){
	case MD_BLOCK_QUOTE: o->r += "<blockquote>\n"; break;
	case MD_BLOCK_UL: o->r += "<ul>\n"; break;
	case MD_BLOCK_OL: {
		unsigned start = ((MD_BLOCK_OL_DETAIL*)d)->start;
		o->r += start == 1 ? ss_("<ol>\n") :
				"<ol start=\""+itos((int64_t)start)+"\">\n";
		break;
	}
	case MD_BLOCK_LI: {
		MD_BLOCK_LI_DETAIL *li = (MD_BLOCK_LI_DETAIL*)d;
		o->r += "<li>";
		if(li->is_task)
			o->r += li->task_mark == ' ' ?
					"<input type=\"checkbox\" disabled> " :
					"<input type=\"checkbox\" disabled checked> ";
		break;
	}
	case MD_BLOCK_HR: o->r += "<hr>\n"; break;
	case MD_BLOCK_H:
		o->r += "<h"+itos((int64_t)((MD_BLOCK_H_DETAIL*)d)->level)+">";
		break;
	// simplified: no language class on a fenced block; a page highlights
	// nothing yet
	case MD_BLOCK_CODE: o->r += "<pre><code>"; break;
	case MD_BLOCK_P: o->r += "<p>"; break;
	case MD_BLOCK_TABLE: o->r += "<table>\n"; break;
	case MD_BLOCK_THEAD: o->r += "<thead>\n"; break;
	case MD_BLOCK_TBODY: o->r += "<tbody>\n"; break;
	case MD_BLOCK_TR: o->r += "<tr>"; break;
	case MD_BLOCK_TH:
	case MD_BLOCK_TD: {
		static const char *align[] = {"", " style=\"text-align:left\"",
			" style=\"text-align:center\"", " style=\"text-align:right\""};
		unsigned a = ((MD_BLOCK_TD_DETAIL*)d)->align;
		o->r += ss_(t == MD_BLOCK_TH ? "<th" : "<td")+align[a < 4 ? a : 0]+">";
		break;
	}
	default: break;
	}
	return 0;
}

static int leave_block(MD_BLOCKTYPE t, void *d, void *u)
{
	Out *o = (Out*)u;
	switch(t){
	case MD_BLOCK_QUOTE: o->r += "</blockquote>\n"; break;
	case MD_BLOCK_UL: o->r += "</ul>\n"; break;
	case MD_BLOCK_OL: o->r += "</ol>\n"; break;
	case MD_BLOCK_LI: o->r += "</li>\n"; break;
	case MD_BLOCK_H:
		o->r += "</h"+itos((int64_t)((MD_BLOCK_H_DETAIL*)d)->level)+">\n";
		break;
	case MD_BLOCK_CODE: o->r += "</code></pre>\n"; break;
	case MD_BLOCK_P: o->r += "</p>\n"; break;
	case MD_BLOCK_TABLE: o->r += "</table>\n"; break;
	case MD_BLOCK_THEAD: o->r += "</thead>\n"; break;
	case MD_BLOCK_TBODY: o->r += "</tbody>\n"; break;
	case MD_BLOCK_TR: o->r += "</tr>\n"; break;
	case MD_BLOCK_TH: o->r += "</th>"; break;
	case MD_BLOCK_TD: o->r += "</td>"; break;
	default: break;
	}
	return 0;
}

static int enter_span(MD_SPANTYPE t, void *d, void *u)
{
	Out *o = (Out*)u;
	switch(t){
	case MD_SPAN_EM: o->r += "<em>"; break;
	case MD_SPAN_STRONG: o->r += "<strong>"; break;
	case MD_SPAN_A: {
		MD_SPAN_A_DETAIL *a = (MD_SPAN_A_DETAIL*)d;
		open_link(o, a->href, a->title);
		break;
	}
	// simplified: an image is a link to it, never loaded -- an image from
	// anywhere tells its host who reads the page. The forum's own images
	// are step 5 of the forum plan.
	case MD_SPAN_IMG: {
		MD_SPAN_IMG_DETAIL *i = (MD_SPAN_IMG_DETAIL*)d;
		open_link(o, i->src, i->title);
		o->r += "[image: ";
		break;
	}
	case MD_SPAN_CODE: o->r += "<code>"; break;
	case MD_SPAN_DEL: o->r += "<del>"; break;
	case MD_SPAN_SPOILER: o->r += "<span class=\"spoiler\" tabindex=\"0\">"; break;
	default: break;
	}
	return 0;
}

static int leave_span(MD_SPANTYPE t, void *d, void *u)
{
	Out *o = (Out*)u;
	switch(t){
	case MD_SPAN_EM: o->r += "</em>"; break;
	case MD_SPAN_STRONG: o->r += "</strong>"; break;
	case MD_SPAN_A:
	case MD_SPAN_IMG:
		if(t == MD_SPAN_IMG)
			o->r += "]";
		if(!o->links.empty()){
			if(o->links.back())
				o->r += "</a>";
			o->links.pop_back();
		}
		break;
	case MD_SPAN_CODE: o->r += "</code>"; break;
	case MD_SPAN_DEL: o->r += "</del>"; break;
	case MD_SPAN_SPOILER: o->r += "</span>"; break;
	default: break;
	}
	return 0;
}

// Text with "#1234", a thread's number after a # that does not follow a
// word, as a link to the thread, and "@name" (a name's characters after
// an @ that does not follow a word, as Hearth's mentions read it) as one
// to the account's page. Their class tells them from a link the writer
// made (Hearth's limits count those).
static void refs(Out *o, const char *s, size_t n)
{
	size_t done = 0;
	for(size_t i = 0; i < n; i++){
		char before = i > 0 ? s[i - 1] : o->r.empty() ? ' ' : o->r.back();
		if(s[i] == '@' && !isalnum((unsigned char)before) && before != '_'){
			size_t e = i + 1;
			while(e < n && e - i <= 80 && (isalnum((unsigned char)s[e]) ||
					s[e] == '_' || s[e] == '-'))
				e++;
			if(e == i + 1)
				continue;
			escape(o->r, s + done, i - done);
			const ss_ name(s + i + 1, e - i - 1);
			o->r += "<a class=\"ref\" href=\"/u/"+name+"\">@"+name+"</a>";
			done = i = e;
			i--;
			continue;
		}
		if(s[i] != '#' || isalnum((unsigned char)before) || before == '_')
			continue;
		size_t e = i + 1;
		while(e < n && e - i <= 12 && isdigit((unsigned char)s[e]))
			e++;
		if(e == i + 1 || e - i > 12 || (e < n &&
				(isalnum((unsigned char)s[e]) || s[e] == '_')))
			continue;
		escape(o->r, s + done, i - done);
		const ss_ id(s + i + 1, e - i - 1);
		o->r += "<a class=\"ref\" href=\"/t/"+id+"\">#"+id+"</a>";
		done = i = e;
		i--;
	}
	escape(o->r, s + done, n - done);
}

static int text(MD_TEXTTYPE t, const MD_CHAR *s, MD_SIZE n, void *u)
{
	Out *o = (Out*)u;
	switch(t){
	case MD_TEXT_NULLCHAR: o->r += "\xEF\xBF\xBD"; break;
	case MD_TEXT_BR: o->r += "<br>\n"; break;
	case MD_TEXT_SOFTBR: o->r += "\n"; break;
	case MD_TEXT_ENTITY: {
		// "&name;", "&#123;" or "&#x1F;" as md4c found it: kept, so the
		// browser reads it, unless it holds anything else
		bool plain = n >= 3 && s[0] == '&' && s[n - 1] == ';';
		for(MD_SIZE i = 1; plain && i + 1 < n; i++)
			plain = isalnum((unsigned char)s[i]) || s[i] == '#';
		if(plain)
			o->r.append(s, n);
		else
			escape(o->r, s, n);
		break;
	}
	case MD_TEXT_NORMAL:
		if(o->links.empty()){
			refs(o, s, n);
			break;
		}
		// fall through
	default: escape(o->r, s, n); break;
	}
	return 0;
}

ss_ to_html(const ss_ &md)
{
	MD_PARSER p = {};
	p.abi_version = 0;
	p.flags = MD_FLAG_NOHTML | MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH |
			MD_FLAG_TASKLISTS | MD_FLAG_PERMISSIVEURLAUTOLINKS |
			MD_FLAG_PERMISSIVEWWWAUTOLINKS | MD_FLAG_SPOILERS;
	p.enter_block = enter_block;
	p.leave_block = leave_block;
	p.enter_span = enter_span;
	p.leave_span = leave_span;
	p.text = text;
	Out o;
	if(md_parse(md.c_str(), (MD_SIZE)md.size(), &p, &o) != 0){
		// md4c fails only on memory; the text escaped is still the text
		ss_ r = "<p>";
		escape(r, md.c_str(), md.size());
		return r+"</p>\n";
	}
	return o.r;
}

}
}
// vim: set noet ts=4 sw=4:
