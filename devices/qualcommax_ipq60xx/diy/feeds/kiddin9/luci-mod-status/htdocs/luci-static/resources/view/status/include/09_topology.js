'use strict';
'require baseclass';
'require dom';
'require rpc';
'require poll';

/* ═════════════════════════════════════════════════════════════════════════════
   网络拓扑 —— 新增的概览页卡片

   装载：index.js 自动发现 view/status/include/*.js 并按文件名排序，
   09 排在 08_stats（状态卡）之后、10_system（Kwrt 那张带推广链接的系统信息）
   之前，正好把推广卡挤到折叠线以下。

   数据来源（全部是现有 ubus 对象，不新增后端）：
     luci-rpc  getDHCPLeases        -> { dhcp_leases: [{ macaddr, ipaddr, hostname, expires }] }
     iwinfo    devices              -> { radio0: {...}, radio1: {...} }
     iwinfo    assoclist(device)    -> { results: [{ mac, signal, rx: {bitrate}, tx: {bitrate} }] }
     network.interface.wan status   -> { up, l3_device, "ipv4-address": [...] }

   任何一项失败都不影响整张图：拿不到 assoclist 时所有终端归到「有线 / 未知」列，
   拿不到租约时显示空态。宁可少画，也不让整页报错。
   ═════════════════════════════════════════════════════════════════════════════ */

var callLeases = rpc.declare({
	object: 'luci-rpc',
	method: 'getDHCPLeases',
	expect: { dhcp_leases: [] }
});

var callIwinfoDevices = rpc.declare({
	object: 'iwinfo',
	method: 'devices',
	nobatch: true,
	expect: {}
});

var callAssoclist = rpc.declare({
	object: 'iwinfo',
	method: 'assoclist',
	params: [ 'device' ],
	nobatch: true,
	expect: { results: [] }
});

var callWanStatus = rpc.declare({
	object: 'network.interface.wan',
	method: 'status',
	expect: {}
});

/* ─── 常量 ─────────────────────────────────────────────────────────────────── */
var VB_W    = 1000;   /* SVG 逻辑宽度 */
var DW      = 322;    /* 设备卡宽 */
var DH      = 62;     /* 设备卡高 */
var DGAP    = 14;
var RT_W    = 372;    /* 路由器卡宽 */
var RT_H    = 136;
var Y_NET   = 26;     /* 互联网节点顶部 */
var Y_RT    = 168;    /* 路由器顶部 */
var Y_SPLIT = Y_RT + RT_H + 46;   /* 分叉水平线 */
var Y_GRP   = Y_SPLIT + 30;       /* 分组标题 */
var Y_DEV   = Y_GRP + 26;         /* 第一行设备顶部 */
var COL_L   = 28;
var COL_R   = VB_W - 28 - DW;
var MAX_PER_COL = 9;

var SVG_NS = 'http://www.w3.org/2000/svg';

function svgEl(tag, attrs) {
	var e = document.createElementNS(SVG_NS, tag);
	if (attrs)
		for (var k in attrs)
			if (attrs[k] != null) e.setAttribute(k, attrs[k]);
	return e;
}

/* ─── 设备图标：按主机名/厂商猜类型 ───────────────────────────────────────── */
var ICONS = {
	phone: 'M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm4 16h2',
	pc:    'M3 4h18v11H3zM8 20h8M12 15v5',
	nas:   'M4 4h16v5H4zM4 13h16v7H4zM7 6.5h.01M7 15.5h.01',
	tv:    'M3 5h18v12H3zM8 21h8',
	iot:   'M12 3v3M12 18v3M3 12h3M18 12h3M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6',
	ap:    'M5 12.5a7 7 0 0 1 14 0M8 15.5a4 4 0 0 1 8 0M12 19h.01',
	router:'M3 13h18v6H3zM7 16h.01M11 16h.01M12 9V4M9 6l3-2 3 2',
	cloud: 'M17.5 19a4.5 4.5 0 0 0 .2-9 6 6 0 0 0-11.5 1.6A3.5 3.5 0 0 0 7 19z',
	unknown: 'M12 17h.01M9.1 9a3 3 0 1 1 4 2.8c-.8.4-1.1 1-1.1 1.9'
};

function guessIcon(host) {
	var h = (host || '').toLowerCase();
	if (/iphone|android|redmi|mi\s*\d|huawei|oppo|vivo|honor|pixel|galaxy|phone/.test(h)) return 'phone';
	if (/tv|box|shield|appletv|firestick|roku/.test(h)) return 'tv';
	if (/^ds\d|nas|synology|qnap|diskstation|truenas|mycloud/.test(h)) return 'nas';
	if (/laptop|macbook|thinkpad|pc|desktop|windows|imac/.test(h)) return 'pc';
	if (/cam|sensor|bulb|plug|socket|thermostat|esp|tasmota|tuya/.test(h)) return 'iot';
	if (/ap|repeater|mesh/.test(h)) return 'ap';
	return 'unknown';
}

/* ─── 取数 ─────────────────────────────────────────────────────────────────── */
function firstIpv4(wan) {
	var a = wan && (wan['ipv4-address'] || wan['ipv6-address']);
	if (Array.isArray(a) && a.length)
		return a[0].address || null;
	return null;
}

/* 路由器节点底部那四个数字复用同一个 CGI，不另开后端。
   注意它不在 @stats 里，用原生 fetch 拿，跟 08_stats.js 用的是同一个 URL，
   浏览器会走 HTTP 缓存，30 秒一次的成本可以忽略。 */
function fetchSysStats() {
	return fetch('/cgi-bin/luci/admin/tools/get_netdev_stats?fast=1',
			{ credentials: 'same-origin' })
		.then(function(r) { return r.json(); })
		.catch(function() { return null; });
}

function fetchTopo() {
	return Promise.all([
		L.resolveDefault(callLeases(), null),
		L.resolveDefault(callIwinfoDevices(), null),
		L.resolveDefault(callWanStatus(), null),
		fetchSysStats()
	]).then(function(r) {
		var leases = (r[0] && Array.isArray(r[0].dhcp_leases)) ? r[0].dhcp_leases : [];
		var radios = r[1] || {};
		var wan    = r[2] || {};
		var sys    = r[3] || null;

		/* 找出所有 up 的无线接口，逐个取 assoclist */
		var devNames = [];
		Object.keys(radios).forEach(function(k) {
			var v = radios[k];
			if (v && (v.up === true || v.up === 1 || v.up === 'true'))
				devNames.push(v.device || v.ifname || k);
		});

		if (!devNames.length)
			return { leases: leases, wifiMacs: {}, wan: wan, sys: sys, wifiUp: false };

		return Promise.all(devNames.map(function(n) {
			return L.resolveDefault(callAssoclist(n), []);
		})).then(function(lists) {
			var macs = {};
			lists.forEach(function(list) {
				var arr = Array.isArray(list) ? list : (list && list.results) || [];
				arr.forEach(function(a) {
					if (a && a.mac)
						macs[String(a.mac).toLowerCase()] = {
							signal: a.signal,
							bitrate: (a.rx && a.rx.bitrate) || (a.tx && a.tx.bitrate) || null
						};
				});
			});
			return { leases: leases, wifiMacs: macs, wan: wan, sys: sys, wifiUp: true };
		});
	}).catch(function() {
		return { leases: [], wifiMacs: {}, wan: null, sys: null, wifiUp: false };
	});
}

/* ─── 布局计算 ─────────────────────────────────────────────────────────────── */
function buildModel(topo) {
	var wifi = [], wired = [];

	topo.leases.forEach(function(l) {
		var mac = String(l.macaddr || '').toLowerCase();
		if (!mac || mac === '00:00:00:00:00:00')
			return;

		var dev = {
			mac: mac,
			ip: l.ipaddr || '—',
			host: (l.hostname && l.hostname !== '*') ? l.hostname : '未知设备',
			expires: l.expires,
			wifi: !!topo.wifiMacs[mac],
			meta: topo.wifiMacs[mac] || null
		};
		(dev.wifi ? wifi : wired).push(dev);
	});

	/* 无线按信号强度降序，有线按 IP 末段，保证每次刷新顺序稳定不跳动 */
	wifi.sort(function(a, b) {
		return (b.meta && b.meta.signal || -999) - (a.meta && a.meta.signal || -999);
	});
	wired.sort(function(a, b) {
		var f = function(x) { return parseInt(String(x.ip).split('.').pop(), 10) || 0; };
		return f(a) - f(b);
	});

	var lCount = wired.length, rCount = wifi.length;
	var rows   = Math.max(Math.min(lCount, MAX_PER_COL), Math.min(rCount, MAX_PER_COL), 1);
	var height = Y_DEV + rows * (DH + DGAP) - DGAP + 26;

	return {
		wired: wired, wifi: wifi,
		rows: rows, height: Math.max(height, 520),
		wifiUp: topo.wifiUp,
		wanIp: firstIpv4(topo.wan)
	};
}

/* ─── 绘制 ─────────────────────────────────────────────────────────────────── */
var uid = 0;

function drawNode(g, x, y, w, h, cls, icon, title, sub, tone) {
	var grp = svgEl('g', { 'class': 'kw2-node ' + (cls || ''), transform: 'translate(' + x + ',' + y + ')' });

	if (tone)
		grp.classList.add('is-' + tone);

	grp.appendChild(svgEl('rect', {
		'class': 'kw2-box', x: 0, y: 0, width: w, height: h, rx: 12
	}));

	var ic = svgEl('g', { transform: 'translate(16,' + (h / 2 - 10) + ')' });
	var p = svgEl('path', { d: ICONS[icon] || ICONS.unknown });
	ic.appendChild(p);
	grp.appendChild(ic);

	grp.appendChild(svgEl('text', {
		'class': 'kw2-name', x: 46, y: h / 2 - 2
	})).textContent = title;

	grp.appendChild(svgEl('text', {
		'class': 'kw2-sub', x: 46, y: h / 2 + 15
	})).textContent = sub;

	return grp;
}

function drawFlow(pathD, tone) {
	/* 底层静态线 + 上层一颗沿路径运动的光点 */
	var g = svgEl('g', { 'class': 'kw2-link is-' + tone });
	g.appendChild(svgEl('path', { 'class': 'kw2-line', d: pathD }));

	var dot = svgEl('circle', { 'class': 'kw2-dot', r: 2.6 });
	var anim = svgEl('animateMotion', {
		dur: (tone === 'wan' ? 3.4 : 4.2) + 's',
		repeatCount: 'indefinite',
		path: pathD
	});
	dot.appendChild(anim);
	g.appendChild(dot);

	return g;
}

function buildSvg(model) {
	var id = 'kw2-' + (++uid);
	var svg = svgEl('svg', {
		viewBox: '0 0 ' + VB_W + ' ' + model.height,
		preserveAspectRatio: 'xMidYMin meet',
		'class': 'kw2-svg'
	});

	/* 点阵背景 */
	var defs = svgEl('defs');
	var pat = svgEl('pattern', {
		id: id + '-dots', width: 22, height: 22,
		patternUnits: 'userSpaceOnUse'
	});
	pat.appendChild(svgEl('circle', { cx: 1, cy: 1, r: 1, 'class': 'kw2-dotpat' }));
	defs.appendChild(pat);
	svg.appendChild(defs);
	svg.appendChild(svgEl('rect', {
		width: VB_W, height: model.height, fill: 'url(#' + id + '-dots)'
	}));

	/* ── 互联网 ── */
	var netX = VB_W / 2 - 130;
	var netNode = drawNode(svg, netX, Y_NET, 260, 62, 'kw2-net', 'cloud',
		'互联网', model.wanIp || '未获取到公网地址', 'wan');
	svg.appendChild(netNode);

	/* ── 路由器 ── */
	var rtX = VB_W / 2 - RT_W / 2;
	var rt = svgEl('g', { 'class': 'kw2-node kw2-rt', transform: 'translate(' + rtX + ',' + Y_RT + ')' });
	rt.appendChild(svgEl('rect', { 'class': 'kw2-box', x: 0, y: 0, width: RT_W, height: RT_H, rx: 18 }));
	rt.appendChild(svgEl('rect', { 'class': 'kw2-rt-tint', x: 0, y: 0, width: RT_W, height: RT_H, rx: 18 }));

	/* 贴边蚂蚁线：用 rect 而不是 circle。circle 的半径按卡片宽度算会溢出到
	   互联网节点外面，视觉上变成一个大破圈；rect 沿圆角边框流动才收得住。 */
	rt.appendChild(svgEl('rect', {
		'class': 'kw2-halo',
		x: -7, y: -7,
		width: RT_W + 14, height: RT_H + 14, rx: 24
	}));

	var rtIcon = svgEl('g', { transform: 'translate(24,26)' });
	rtIcon.appendChild(svgEl('path', { d: ICONS.router }));
	rt.appendChild(rtIcon);

	var t1 = svgEl('text', { 'class': 'kw2-rt-title', x: 54, y: 44 });
	t1.textContent = 'AX1800 Pro';
	rt.appendChild(t1);

	var t2 = svgEl('text', { 'class': 'kw2-rt-sub', x: 55, y: 62 });
	t2.textContent = 'IPQ6000 · NSS 硬件加速';
	rt.appendChild(t2);

	/* 底部四个小指标占位（由 update 填入真实值） */
	var stats = [
		{ k: 'cpu',  l: 'CPU'  },
		{ k: 'temp', l: '温度' },
		{ k: 'mem',  l: '内存' },
		{ k: 'up',   l: '运行' }
	];
	stats.forEach(function(s, i) {
		var cw = (RT_W - 48) / 4;
		var cx = 24 + i * cw;
		rt.appendChild(svgEl('line', {
			'class': 'kw2-rt-sep', x1: cx, y1: 84, x2: cx, y2: 116
		}));
		var kv = svgEl('text', { 'class': 'kw2-rt-k', x: cx + 12, y: 100 });
		kv.textContent = s.l;
		rt.appendChild(kv);
		var vv = svgEl('text', { 'class': 'kw2-rt-v', x: cx + 12, y: 118 });
		vv.textContent = '—';
		vv.setAttribute('data-kw', s.k);
		rt.appendChild(vv);
	});

	svg.appendChild(rt);

	/* ── 连线：互联网 → 路由器 ── */
	svg.appendChild(drawFlow('M' + VB_W / 2 + ',' + (Y_NET + 62) + ' V' + Y_RT, 'wan'));

	/* ── 连线：路由器 → 左右两列 ── */
	var lcx = COL_L + DW / 2;
	var rcx = COL_R + DW / 2;

	svg.appendChild(drawFlow(
		'M' + VB_W / 2 + ',' + (Y_RT + RT_H) + ' V' + Y_SPLIT + ' H' + lcx + ' V' + (Y_DEV - 8),
		'lan'));
	svg.appendChild(drawFlow(
		'M' + VB_W / 2 + ',' + (Y_RT + RT_H) + ' V' + Y_SPLIT + ' H' + rcx + ' V' + (Y_DEV - 8),
		'wl'));

	/* ── 分组标题 ── */
	var gl = svgEl('text', { 'class': 'kw2-grp', x: lcx, y: Y_GRP, 'text-anchor': 'middle' });
	gl.textContent = '有线 / 未知  ·  ' + model.wired.length;
	svg.appendChild(gl);

	var gr = svgEl('text', { 'class': 'kw2-grp', x: rcx, y: Y_GRP, 'text-anchor': 'middle' });
	gr.textContent = '无线  ·  ' + model.wifi.length + (model.wifiUp ? '' : '  (无线未启动)');
	if (!model.wifiUp) gr.classList.add('is-warn');
	svg.appendChild(gr);

	/* ── 设备 ── */
	function place(list, x, colKey) {
		list.slice(0, MAX_PER_COL).forEach(function(d, i) {
			var y = Y_DEV + i * (DH + DGAP);
			var icon = d.wifi ? (d.host.match(/phone|iphone|android|redmi/i) ? 'phone' : 'ap') : guessIcon(d.host);
			var node = drawNode(svg, x, y, DW, DH, 'kw2-dev', icon, d.host, d.ip,
				d.wifi ? 'wl' : 'lan');
			node.setAttribute('data-kwdev', colKey + i);
			svg.appendChild(node);

			/* 列内竖线连接 */
			if (i > 0) {
				svg.insertBefore(drawFlow(
					'M' + (x + DW / 2) + ',' + (y - DGAP) + ' V' + y,
					d.wifi ? 'wl' : 'lan'), node);
			}
		});

		if (list.length > MAX_PER_COL) {
			var more = svgEl('text', {
				'class': 'kw2-more',
				x: x + DW / 2,
				y: Y_DEV + MAX_PER_COL * (DH + DGAP) - DGAP + 18,
				'text-anchor': 'middle'
			});
			more.textContent = '还有 ' + (list.length - MAX_PER_COL) + ' 台未显示';
			svg.appendChild(more);
		}
	}

	place(model.wired, COL_L, 'l');
	place(model.wifi, COL_R, 'w');

	if (!model.wired.length && !model.wifi.length) {
		var hint = svgEl('text', {
			'class': 'kw2-empty', x: VB_W / 2, y: Y_DEV + 42, 'text-anchor': 'middle'
		});
		hint.textContent = '暂无在线终端 —— DHCP 租约列表为空';
		svg.appendChild(hint);
	}

	return svg;
}

/* ─── 导出 ─────────────────────────────────────────────────────────────────── */
var lastModel = null;
var hostRefs = null;
var pollBound = false;

function setRtStats(container, data) {
	if (!data || !container) return;

	/* 后端 JSON 是下划线命名（cpu_pct / cpu_temp / mem_pct），
	   这里不能按驼峰读 —— 否则四个数字全是 0 或「—」。 */
	var pick = function(a, b) {
		return (data[a] != null && data[a] !== '') ? data[a] : data[b];
	};

	var cpuPct  = pick('cpu_pct', 'cpuPct');
	var cpuTemp = pick('cpu_temp', 'cpuTemp');
	var memPct  = pick('mem_pct', 'memPct');
	var upSec   = Number(data.uptime) || 0;

	var upTxt = (function(s) {
		var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
		return h > 0 ? h + 'h' + m + 'm' : m + 'm';
	})(upSec);

	var map = {
		cpu:  (cpuPct  != null) ? Math.round(Number(cpuPct))  + '%' : '—',
		temp: (cpuTemp != null) ? Math.round(Number(cpuTemp)) + '°' : '—',
		mem:  (memPct  != null) ? Math.round(Number(memPct))  + '%' : '—',
		up:   upTxt
	};

	container.querySelectorAll('text[data-kw]').forEach(function(t) {
		var v = map[t.getAttribute('data-kw')];
		if (v != null) t.textContent = v;
	});
}

return baseclass.extend({
	title: _('Network Topology'),

	/* 拓扑 DOM 上百个节点，缓存进 sessionStorage 无意义还会顶爆配额 */
	disableCache: true,

	load: function() {
		return fetchTopo();
	},

	render: function(topo) {
		topo = topo || { leases: [], wifiMacs: {}, wan: null, sys: null, wifiUp: false };

		var model = buildModel(topo);
		lastModel = model;

		/* 即使没有终端也照画骨架（互联网 + 路由器 + 空的左右分组），
		   这样卡片高度稳定，不会因为设备掉线整块消失又冒出来。 */
		var svg = buildSvg(model);
		setRtStats(svg, topo.sys);

		/* 悬浮详情浮层：用 HTML 绝对定位，不用 foreignObject（老浏览器兼容差） */
		var tip = E('div', { 'class': 'kw2-tip', style: 'display:none' });

		var stage = E('div', { 'class': 'kw2-stage' }, [svg, tip]);
		hostRefs = stage;

		/* 给每个设备节点绑 hover */
		var all = model.wired.concat(model.wifi);
		svg.querySelectorAll('.kw2-dev').forEach(function(g, idx) {
			var d = all[idx];
			if (!d) return;

			g.addEventListener('mouseenter', function(ev) {
				g.classList.add('is-hover');
				svg.querySelectorAll('.kw2-link').forEach(function(l) {
					l.classList.add('is-dim');
				});

				var sig = d.meta && d.meta.signal != null
					? d.meta.signal + ' dBm' : null;
				var rate = d.meta && d.meta.bitrate
					? Math.round(d.meta.bitrate / 1000) + ' Mbps' : null;

				var rows = [
					['IP', d.ip],
					['MAC', d.mac],
					['接入', d.wifi ? '无线' : '有线 / 未知']
				];
				if (sig)  rows.push(['信号', sig]);
				if (rate) rows.push(['协商', rate]);

				tip.innerHTML = '';
				tip.appendChild(E('div', { 'class': 'kw2-tip-title' }, d.host));
				rows.forEach(function(r) {
					tip.appendChild(E('div', { 'class': 'kw2-tip-row' }, [
						E('span', { 'class': 'kw2-tip-k' }, r[0]),
						E('span', { 'class': 'kw2-tip-v' }, String(r[1]))
					]));
				});

				tip.style.display = 'block';
				var box = stage.getBoundingClientRect();
				var tx = ev.clientX - box.left + 16;
				var ty = ev.clientY - box.top + 12;
				if (tx + 220 > box.width) tx = box.width - 228;
				tip.style.left = Math.max(4, tx) + 'px';
				tip.style.top = ty + 'px';
			});

			g.addEventListener('mousemove', function(ev) {
				var box = stage.getBoundingClientRect();
				var tx = ev.clientX - box.left + 16;
				var ty = ev.clientY - box.top + 12;
				if (tx + 220 > box.width) tx = box.width - 228;
				tip.style.left = Math.max(4, tx) + 'px';
				tip.style.top = ty + 'px';
			});

			g.addEventListener('mouseleave', function() {
				g.classList.remove('is-hover');
				tip.style.display = 'none';
				svg.querySelectorAll('.kw2-link').forEach(function(l) {
					l.classList.remove('is-dim');
				});
			});
		});

		if (!pollBound) {
			pollBound = true;
			poll.add(function() {
				return fetchTopo().then(function(t) {
					var m = buildModel(t);

					/* 只有终端增删才整图重画；否则仅刷路由器上那四个数字，
					   避免每 30 秒重建 SVG 导致连线的流动动画从头开始。 */
					if (!lastModel ||
						m.wired.length !== lastModel.wired.length ||
						m.wifi.length  !== lastModel.wifi.length) {
						var c = hostRefs && hostRefs.parentNode;
						if (c) {
							dom.content(c, this.render(t));
							return;
						}
					}

					var svgNow = hostRefs && hostRefs.querySelector('svg');
					if (svgNow) {
						lastModel = m;
						setRtStats(svgNow, t.sys);
					}
				}.bind(this)).catch(function() {});
			}, 30);
		}

		return stage;
	}
});
