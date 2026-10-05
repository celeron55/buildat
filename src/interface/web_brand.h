// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <fstream>
#include <sstream>

namespace interface
{
	// [HTML_BRAND]: Buildat's look on the HTML an app serves -- Hearth's
	// pages and the Starport's ID page. The user's pick of
	// local/options_for_HTML_BRAND, c_quiet: the launcher's darker ground,
	// panels with grey borders, purple only on the header's rule and a
	// quote's bar; cyan on focus and the answered box, amber on a form's
	// main button, a red for errors. The font and the logo are the app's
	// own files under /brand/, so a page loads nothing from another origin.
	namespace web_brand
	{
		static const char *css =
			"@font-face{font-family:Overpass;src:url(/brand/overpass.ttf)}"
			"@font-face{font-family:Overpass Mono;"
			"src:url(/brand/overpass_mono.ttf)}"
			"body{max-width:46em;margin:0 auto;padding:0 16px;"
			"font:16px/1.55 Overpass,sans-serif;color:#ddd;background:#1b1b22}"
			"header{border-bottom:1px solid #8c33f2;padding:.6em 0;display:flex;"
			"gap:1em;align-items:center;flex-wrap:wrap}"
			"header .brand{display:flex;gap:.5em;align-items:center;"
			"font-size:1.2em;color:#fff}"
			"header img{height:28px;width:28px}"
			"header form{display:flex;gap:.4em;flex:1;min-width:12em}"
			"header form input{flex:1;min-width:0}"
			"a{color:#fff;text-decoration:none}a:hover{text-decoration:underline}"
			"h1,h2{color:#fff;font-weight:normal}"
			".meta{color:#999;font-size:.9em}.meta a{color:#bbb}"
			".box{border:1px solid #3a3a48;border-radius:4px;padding:.5em 1em;"
			"margin:1em 0;background:#23232c}"
			".answer{border:2px solid #26d9ff}"
			"ul.list{padding-left:1.2em}"
			"mark{background:#33395a;color:#fff}"
			"pre{overflow-x:auto;background:#15151a;padding:.5em;"
			"border-radius:3px}"
			"code{font-family:\"Overpass Mono\",monospace;background:#15151a;"
			"padding:0 .2em}pre code{padding:0}"
			"blockquote{border-left:3px solid #8c33f2;margin:0;padding-left:1em;"
			"color:#bbb}"
			"td,th{border:1px solid #3a3a48;padding:0 .5em}"
			"table{border-collapse:collapse}"
			".spoiler{background:#666;color:#666;border-radius:2px}"
			".spoiler:hover,.spoiler:focus{background:none;color:inherit}"
			"input,button,select{font:inherit;color:#ddd;background:#15151a;"
			"border:1px solid #666;border-radius:3px;padding:.3em .5em}"
			"button{background:#444;cursor:pointer}"
			"button:hover{background:#8c8c8c}"
			"input:focus,button:focus,select:focus,a:focus{"
			"outline:2px solid #26d9ff;outline-offset:1px}"
			"form[id]>button:first-of-type{background:#ff9e1f;color:#111;"
			"border-color:#ff9e1f}"
			"fieldset{border:1px solid #3a3a48;border-radius:4px;margin:1em 0}"
			"#err{color:#ff5c5c}#ok{color:#26d9ff}b{color:#fff}";

		static const char *logo = "<img src=\"/brand/logo.png\" alt=\"\">";

		// The file at /brand/<name>, from the share's client/data (which
		// CMakeLists installs for a server build too), and its type; false
		// for no such file
		inline bool file(const ss_ &share_path, const ss_ &name, ss_ &data,
				ss_ &type)
		{
			ss_ path;
			if(name == "overpass.ttf"){
				path = "/client/data/Fonts/Overpass-Regular.ttf";
				type = "font/ttf";
			} else if(name == "overpass_mono.ttf"){
				path = "/client/data/Fonts/OverpassMono-Regular.ttf";
				type = "font/ttf";
			} else if(name == "logo.png"){
				path = "/client/data/buildat_logo.png";
				type = "image/png";
			} else {
				return false;
			}
			std::ifstream f(share_path+path, std::ios::binary);
			std::ostringstream os;
			os<<f.rdbuf();
			data = os.str();
			return f.good() && !data.empty();
		}
	}
}
