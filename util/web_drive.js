#!/usr/bin/env node
// Drives a headless browser through steps, for checks of the web client
// ([WEB_CLIENT]) in a real browser: Firefox over WebDriver BiDi, Chrome over
// the DevTools protocol, with Node's own WebSocket (Node 22 or newer) and no
// packages. util/web_drive.sh starts the server and the browser and runs
// this; it can be run by hand against a browser already listening:
//
//   node util/web_drive.js --browser firefox|chrome --port 9334 \
//       --steps steps.json --log page.log [--var NAME=value ...]
//
// A steps file is a JSON list of steps, each a list:
//   ["nav", url]            open the page, and wait for it to load
//   ["wait", ms]
//   ["waitlog", regex, s]   until a line of the page's console matches, one
//                           after the last waitlog's, at most s seconds
//                           (default 60); fails the run if none does
//   ["type", text]          as typed, character by character
//   ["key", name]           Tab, Enter, Escape, Space, Backspace, F1..F12,
//                           Up, Down, Left, Right, or one character
//   ["selall"]              Ctrl+A
//   ["click", x, y]         left button, in CSS pixels
//   ["mouse", x, y]         the pointer there, no button
//   ["tap", x, y]           a finger's touch there and up again
//   ["drag", x0, y0, x1, y1, "touch"]
//                           the left button (or a finger) down at x0, y0,
//                           moved to x1, y1 over half a second, and up
//                           (Firefox only)
//   ["shot", path]          a PNG of the page
//   ["eval", js]            print what the expression gives
//   ["window", n]           the steps after go to the nth top-level window
//                           (0 the first; one a page opened is 1), Firefox
//                           only
// ${NAME} in a string is a --var's value. The page's console goes to the
// log, a line each. Exits 1 when a step fails.
"use strict";
const fs = require("fs");

const args = {vars: {}};
for (let i = 2; i < process.argv.length; i++) {
	const a = process.argv[i];
	if (a === "--var") {
		const [k, ...v] = process.argv[++i].split("=");
		args.vars[k] = v.join("=");
	} else if (a.startsWith("--")) {
		args[a.slice(2)] = process.argv[++i];
	}
}
if (!args.browser || !args.port || !args.steps) {
	console.error("usage: web_drive.js --browser firefox|chrome --port N " +
			"--steps file [--log file] [--var NAME=value ...]");
	process.exit(2);
}
const fill = v => typeof v === "string" ?
		v.replace(/\$\{(\w+)\}/g, (_, k) => k in args.vars ? args.vars[k] : "") : v;
const steps = JSON.parse(fs.readFileSync(args.steps, "utf8")).map(s => s.map(fill));
const logPath = args.log || "/dev/stdout";
const lines = [];
// Where the next waitlog starts looking: past the line the last one matched
let cursor = 0;
function logLine(t) {
	lines.push(t);
	fs.appendFileSync(logPath, t + "\n");
}

// Keys: WebDriver's code points, and the DevTools protocol's key, code
// and Windows key code
const KEYS = {
	Tab: ["", "Tab", 9], Enter: ["", "Enter", 13],
	Escape: ["", "Escape", 27], Space: [" ", "Space", 32],
	Backspace: ["", "Backspace", 8], Up: ["", "ArrowUp", 38],
	Down: ["", "ArrowDown", 40], Left: ["", "ArrowLeft", 37],
	Right: ["", "ArrowRight", 39],
};
for (let n = 1; n <= 12; n++)
	KEYS["F" + n] = [String.fromCharCode(0xE031 + n - 1), "F" + n, 111 + n];

function connect(url) {
	const ws = new WebSocket(url);
	let id = 0;
	const pending = {};
	const handlers = [];
	ws.onmessage = m => {
		const d = JSON.parse(m.data);
		if (d.id && pending[d.id]) {
			pending[d.id](d);
			delete pending[d.id];
		} else if (d.method) {
			for (const h of handlers) h(d);
		}
	};
	const send = (method, params = {}, extra = {}) => new Promise((res, rej) => {
		const i = ++id;
		pending[i] = d => d.error ? rej(new Error(method + ": " +
				JSON.stringify(d.error) + " " + (d.message || ""))) : res(d.result);
		ws.send(JSON.stringify(Object.assign({id: i, method, params}, extra)));
	});
	return new Promise((res, rej) => {
		ws.onopen = () => res({ws, send, on: h => handlers.push(h)});
		ws.onerror = e => rej(new Error("cannot connect to " + url));
	});
}

// What each step does, in each protocol
async function firefox() {
	const c = await connect(`ws://127.0.0.1:${args.port}/session`);
	// WEB_DRIVE_INSECURE=1: a certificate of a check's own CA is taken
	// simplified: the browser's override, not the CA put in the profile
	await c.send("session.new", {capabilities: {alwaysMatch:
			{acceptInsecureCerts: !!process.env.WEB_DRIVE_INSECURE}}});
	c.on(d => {
		if (d.method === "log.entryAdded")
			logLine(d.params.text);
	});
	await c.send("session.subscribe", {events: ["log.entryAdded"]});
	const top = async n => (await c.send("browsingContext.getTree",
			{maxDepth: 0})).contexts[n].context;
	let ctx = await top(0);
	await c.send("browsingContext.setViewport", {context: ctx,
			viewport: {width: 1200, height: 800}});
	const keys = list => c.send("input.performActions", {context: ctx,
			actions: [{type: "key", id: "k", actions: list}]});
	const press = v => [{type: "keyDown", value: v}, {type: "keyUp", value: v}];
	const ops = {
		nav: u => c.send("browsingContext.navigate", {context: ctx, url: u,
				wait: "complete"}),
		type: t => keys([...t].flatMap(press)),
		key: k => keys(press(KEYS[k] ? KEYS[k][0] : k)),
		selall: () => keys([{type: "keyDown", value: ""},
				...press("a"), {type: "keyUp", value: ""}]),
		click: (x, y) => c.send("input.performActions", {context: ctx,
				actions: [{type: "pointer", id: "m", actions: [
				{type: "pointerMove", x, y}, {type: "pointerDown", button: 0},
				{type: "pause", duration: 50}, {type: "pointerUp", button: 0}]}]}),
		mouse: (x, y) => c.send("input.performActions", {context: ctx,
				actions: [{type: "pointer", id: "m", actions: [
				{type: "pointerMove", x, y}]}]}),
		tap: (x, y) => c.send("input.performActions", {context: ctx,
				actions: [{type: "pointer", id: "t", parameters:
				{pointerType: "touch"}, actions: [
				{type: "pointerMove", x, y}, {type: "pointerDown", button: 0},
				{type: "pause", duration: 50}, {type: "pointerUp", button: 0}]}]}),
		drag: (x0, y0, x1, y1, kind) => c.send("input.performActions", {
				context: ctx, actions: [{type: "pointer", id: kind === "touch" ?
				"t" : "m", parameters: {pointerType: kind === "touch" ?
				"touch" : "mouse"}, actions: [
				{type: "pointerMove", x: x0, y: y0},
				{type: "pointerDown", button: 0},
				...[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(i => ({type: "pointerMove",
					duration: 50, x: Math.round(x0 + (x1 - x0) * i / 10),
					y: Math.round(y0 + (y1 - y0) * i / 10)})),
				{type: "pointerUp", button: 0}]}]}),
		shot: async p => {
			const r = await c.send("browsingContext.captureScreenshot", {context: ctx});
			fs.writeFileSync(p, Buffer.from(r.data, "base64"));
		},
		window: async n => { ctx = await top(n); },
		eval: async js => {
			const r = await c.send("script.evaluate", {expression: js,
					target: {context: ctx}, awaitPromise: true});
			console.log("eval:", JSON.stringify(r.result && r.result.value));
		},
	};
	return {ops, end: async () => {
		await c.send("session.end", {});
		c.ws.close();
	}};
}

async function chrome() {
	const list = await (await fetch(`http://127.0.0.1:${args.port}/json/list`)).json();
	const page = list.find(t => t.type === "page");
	const c = await connect(page.webSocketDebuggerUrl);
	c.on(d => {
		if (d.method === "Runtime.consoleAPICalled")
			logLine(d.params.args.map(a => a.value !== undefined ? a.value :
					a.description).join(" "));
		else if (d.method === "Log.entryAdded")
			logLine("[" + d.params.entry.source + "] " + d.params.entry.text);
	});
	await c.send("Runtime.enable");
	await c.send("Log.enable");
	await c.send("Page.enable");
	await c.send("Emulation.setDeviceMetricsOverride", {width: 1200,
			height: 800, deviceScaleFactor: 1, mobile: false});
	const key = async (k, mods = 0) => {
		const [, code, vk] = KEYS[k] || [k, "Key" + k.toUpperCase(),
				k.toUpperCase().charCodeAt(0)];
		const name = KEYS[k] ? (k === "Space" ? " " : code) : k;
		const base = {key: name, code, windowsVirtualKeyCode: vk, modifiers: mods};
		await c.send("Input.dispatchKeyEvent", Object.assign({type: "rawKeyDown"}, base));
		if (!KEYS[k] && mods === 0)
			await c.send("Input.dispatchKeyEvent", {type: "char", text: k});
		await c.send("Input.dispatchKeyEvent", Object.assign({type: "keyUp"}, base));
	};
	let loaded = null;
	c.on(d => {
		if (d.method === "Page.loadEventFired" && loaded)
			loaded();
	});
	const ops = {
		nav: async u => {
			const done = new Promise(r => loaded = r);
			await c.send("Page.navigate", {url: u});
			await done;
		},
		type: async t => {
			for (const ch of t)
				await key(ch);
		},
		key: k => key(k),
		selall: () => key("a", 2),
		click: async (x, y) => {
			for (const type of ["mouseMoved", "mousePressed", "mouseReleased"])
				await c.send("Input.dispatchMouseEvent", {type, x, y,
						button: "left", clickCount: 1});
		},
		mouse: (x, y) => c.send("Input.dispatchMouseEvent", {type: "mouseMoved",
				x, y}),
		tap: async (x, y) => {
			await c.send("Input.dispatchTouchEvent", {type: "touchStart",
					touchPoints: [{x, y}]});
			await c.send("Input.dispatchTouchEvent", {type: "touchEnd",
					touchPoints: []});
		},
		shot: async p => {
			const r = await c.send("Page.captureScreenshot", {format: "png"});
			fs.writeFileSync(p, Buffer.from(r.data, "base64"));
		},
		eval: async js => {
			const r = await c.send("Runtime.evaluate", {expression: js,
					awaitPromise: true, returnByValue: true});
			console.log("eval:", JSON.stringify(r.result && r.result.value));
		},
	};
	return {ops, end: async () => c.ws.close()};
}

(async () => {
	const b = args.browser === "firefox" ? await firefox() :
			args.browser === "chrome" ? await chrome() : null;
	if (!b) {
		console.error("web_drive.js: --browser is firefox or chrome");
		process.exit(2);
	}
	let failed = null;
	for (const [op, ...args] of steps) {
		const [a, c] = args;
		console.log("step:", op, a !== undefined ? a : "", c !== undefined ? c : "");
		try {
			if (op === "wait") {
				await new Promise(r => setTimeout(r, a));
			} else if (op === "waitlog") {
				const re = new RegExp(a);
				const until = Date.now() + (c || 60) * 1000;
				for (;;) {
					const i = lines.findIndex((l, k) => k >= cursor && re.test(l));
					if (i >= 0) {
						cursor = i + 1;
						break;
					}
					if (Date.now() > until)
						throw new Error("no console line matched /" + a + "/");
					await new Promise(r => setTimeout(r, 200));
				}
			} else if (b.ops[op]) {
				await b.ops[op](...args);
			} else {
				throw new Error("no such step");
			}
		} catch (e) {
			failed = op + ": " + e.message;
			break;
		}
	}
	await b.end().catch(() => {});
	if (failed) {
		console.error("web_drive.js: " + failed);
		process.exit(1);
	}
	process.exit(0);
})().catch(e => {
	console.error("web_drive.js: " + e.message);
	process.exit(1);
});
