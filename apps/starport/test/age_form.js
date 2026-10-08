// [SP_AGE_FORM], run by apps/starport/age_form_check.sh: the /id page at
// 360 px. Prints a line per finding, the page's own words.
(async () => {
	const out = [];
	const sleep = ms => new Promise(r => setTimeout(r, ms));
	// The page refuses a frame (frame-ancestors 'none'): its own root held
	// to a phone's width instead.
	// simplified: a width, not a phone's viewport; the page has no media
	// query of its own that would tell them apart
	document.documentElement.style.width = "360px";
	await sleep(300);
	const d = document, w = window;
	const $ = id => d.getElementById(id);
	const box = e => e.getBoundingClientRect();
	let sent = "";
	const fetch0 = w.fetch;
	w.fetch = (u, o) => { sent += (o && o.body) || ""; return fetch0.call(w, u, o); };
	$("toreg").click();
	await sleep(200);
	out.push("year shown before an answer: " + !$("rminor").classList.contains("hide"));
	$("rno").click();
	await sleep(100);
	// At 360 px: the consent line on its own, the buttons on the next, on
	// one line and unwrapped
	const make = d.querySelector("#register button:not([type])");
	const back = $("tologin");
	const consent = $("rconsent").closest("label");
	const ok = box(make).top == box(back).top &&
		box(make).height == box(back).height &&
		box(consent).bottom <= box(make).top &&
		box($("ryear")).bottom <= box(consent).top;
	out.push("layout: " + (ok ? "ok" : JSON.stringify([box(make), box(back),
		box(consent)])));
	$("rname").value = "kid1";
	$("rpassword").value = "kidpass1234";
	$("ryear").value = "2015";
	make.click();
	await sleep(1500);
	out.push("2015 without consent: " + $("err").textContent);
	sent = "";
	$("rname").value = "grown1";
	$("rpassword").value = "grownpass1234";
	$("ryes").click();
	out.push("year hidden on Yes: " + $("rminor").classList.contains("hide"));
	make.click();
	await sleep(1500);
	out.push("Yes sent a year: " + /birth_year/.test(sent) +
		", settings shown: " + !$("settings").classList.contains("hide"));
	$("sno").click();
	$("syear").value = "2015";
	$("setage").click();
	await sleep(1500);
	out.push("settings 2015 without consent: " + $("err").textContent);
	sent = "";
	$("syes").click();
	$("setage").click();
	await sleep(1500);
	out.push("settings Yes: " + $("ok").textContent + ", a year sent: " +
		/birth_year/.test(sent) + ", band: " + $("band").textContent);
	return out.join("\n");
})()
