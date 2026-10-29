'use strict';
'require baseclass';
'require fs';
'require poll';

/* ═════════════════════════════════════════════════════════════════════════════
   概览仪表盘 —— 覆盖 Kwrt 的 feeds/kiddin9/luci-mod-status 原版 08_stats.js

   装载机制（不需要改 index.js）：
     view/status/index.js 的 load() 会 fs.list view/status/include 下所有 .js，
     按文件名排序后逐个 L.require。每个模块导出的对象只要有
     { title, load, render } 就会被自动包成一张 cbi-section 卡片。
     所以本文件放在 diy 覆盖目录里、文件名仍是 08_stats.js，
     就自动顶替原版、且保持原有位置（概览页第一张卡）。

   数据来源（全部沿用现有后端，不新增接口）：
     GET /cgi-bin/luci/admin/tools/get_netdev_stats?fast=1
         -> stats{iface:{rx,tx}} / ip / status / prefer_iface / uptime /
            cpu_pct / cpu_temp / mem_pct / mem_used / mem_total /
            disk_pct / disk_used / disk_total
         （后端 luci/controller/netstat.lua，字段名是硬契约，改名前要同步改那边）
     rpcd file.read  /proc/sys/net/netfilter/nf_conntrack_count   （ACL 已授权）
                     /proc/sys/net/netfilter/nf_conntrack_max
   ═════════════════════════════════════════════════════════════════════════════ */

/* ─── 样式：单文件 + body.kw-dark 切变量，避免切主题时重载 CSS 闪屏 ───────── */
(function setupTheme() {
	var dark = false;

	function detect() {
		try {
			var bg = getComputedStyle(document.body).backgroundColor;
			if (!bg || bg === 'transparent' || bg.indexOf('rgba(0, 0, 0, 0)') === 0)
				return false;
			var m = bg.match(/\d+/g);
			if (!m || m.length < 3) return false;
			return (m[0] * 299 + m[1] * 587 + m[2] * 114) / 1000 < 100;
		} catch (e) { return false; }
	}

	function apply() {
		var d = detect();
		if (d === dark && document.body.classList.contains('kw-dark') === d)
			return;
		dark = d;
		document.body.classList.toggle('kw-dark', d);
	}

	function style() {
		if (document.querySelector('link[data-kw-dash]'))
			return;
		var l = document.createElement('link');
		l.rel = 'stylesheet';
		l.href = (typeof L !== 'undefined' && L.resource)
			? L.resource('netstat/kwrt-dash.css')
			: '/luci-static/resources/netstat/kwrt-dash.css';
		l.setAttribute('data-kw-dash', '1');
		document.head.appendChild(l);
	}

	function boot() {
		if (!document.body) { setTimeout(boot, 40); return; }
		style();
		apply();
		/* argon 切暗色改的是 body 的 style/class，盯住它 */
		try {
			new MutationObserver(apply).observe(document.body, {
				attributes: true, attributeFilter: ['style', 'class']
			});
		} catch (e) {}
	}

	if (window.matchMedia) {
		try {
			window.matchMedia('(prefers-color-scheme: dark)')
				.addEventListener('change', apply);
		} catch (e) {}
	}

	boot();
})();

/* ─── 常量 ─────────────────────────────────────────────────────────────────── */
var SPARK_LEN   = 40;     /* 40 点 × 2 秒 = 80 秒历史 */
var POLL_MS     = 2000;
var SLOW_EVERY  = 5;      /* 慢变量（conntrack）每 5 次轮询刷一次 */
var RING_R      = 36;     /* 环形半径，配合 viewBox 84×84 */
var RING_C      = 2 * Math.PI * RING_R;

/* ─── 状态 ─────────────────────────────────────────────────────────────────── */
var prev      = {};       /* 上一次的 rx/tx 字节，按接口名 */
var lastTime  = 0;
var peakRx    = 0;
var peakTx    = 0;
var lastRx    = 0;        /* 上一次速率，用于趋势箭头 */
var lastTx    = 0;
var sparkRx   = [];
var sparkTx   = [];
var slowTick  = 0;
var slowData  = { conn: null, connMax: null };
var pollAdded = false;
var refs      = null;     /* 当前 DOM 节点引用表 */
var lastData  = null;

/* ─── 格式化 ───────────────────────────────────────────────────────────────── */
function formatRate(bytesPerSec) {
	var bps = bytesPerSec * 8;
	var units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
	var i = 0;
	while (bps >= 1000 && i < units.length - 1) { bps /= 1000; i++; }
	return {
		num:  bps.toFixed(i === 0 ? 0 : (bps >= 100 ? 0 : 1)),
		unit: units[i] + '/s'
	};
}

function formatBytes(v) {
	v = Number(v) || 0;
	if (v >= 1099511627776) return [(v / 1099511627776).toFixed(2), 'TB'];
	if (v >= 1073741824)    return [(v / 1073741824).toFixed(2), 'GB'];
	if (v >= 1048576)       return [(v / 1048576).toFixed(2), 'MB'];
	if (v >= 1024)          return [(v / 1024).toFixed(1), 'KB'];
	return [String(v), 'B'];
}

function formatUptime(sec) {
	sec = Math.floor(Number(sec) || 0);
	var d = Math.floor(sec / 86400);
	var h = Math.floor((sec % 86400) / 3600);
	var m = Math.floor((sec % 3600) / 60);
	if (d > 0) return d + ' 天 ' + h + ' 小时';
	if (h > 0) return h + ' 小时 ' + m + ' 分';
	return m + ' 分 ' + (sec % 60) + ' 秒';
}

function trendOf(cur, old) {
	if (old <= 0 && cur <= 0) return 'flat';
	var ratio = old > 0 ? cur / old : (cur > 0 ? 99 : 1);
	if (ratio > 1.10) return 'up';
	if (ratio < 0.90) return 'down';
	return 'flat';
}

function pctColor(pct, warnAt, badAt) {
	if (pct >= (badAt || 90))  return 'var(--kw-bad)';
	if (pct >= (warnAt || 70)) return 'var(--kw-warn)';
	return 'var(--kw-brand)';
}

/* ─── 挑主用接口（与后端 prefer_iface 配合） ───────────────────────────────── */
function pickWan(stats, preferred) {
	var i;
	for (i = 0; i < preferred.length; i++)
		if (stats[preferred[i]]) return preferred[i];

	/* 动态拨号口，如 pppoe-wan / wwan0_1 */
	var dyn = Object.keys(stats).filter(function(k) {
		return /^(wwan|usb|ppp|lte|qmi|modem)/.test(k) && k.indexOf('_') >= 0;
	})[0];
	if (dyn) return dyn;

	var fixed = ['pppoe-wan', 'lte0', 'usb0', 'wan', 'eth1', 'tun0', 'wg0'];
	for (i = 0; i < fixed.length; i++)
		if (stats[fixed[i]]) return fixed[i];

	return Object.keys(stats).filter(function(k) { return k !== 'lo'; })[0] || '';
}

/* ─── Sparkline ────────────────────────────────────────────────────────────────
   用固定 viewBox 0 0 100 30 + preserveAspectRatio=none 让它随卡片宽度伸缩，
   再用 vector-effect=non-scaling-stroke 保证线宽不被拉变形。
   ──────────────────────────────────────────────────────────────────────────── */
var SVG_NS = 'http://www.w3.org/2000/svg';
var uid = 0;

function svgEl(tag, attrs) {
	var e = document.createElementNS(SVG_NS, tag);
	for (var k in attrs)
		if (attrs[k] != null) e.setAttribute(k, attrs[k]);
	return e;
}

function sparkPoints(values, w, h) {
	var max = Math.max.apply(null, values.concat([1]));
	var n = values.length;
	if (n < 2) return '';
	var step = w / (n - 1);
	var out = [];
	for (var i = 0; i < n; i++) {
		var x = i * step;
		var y = h - (values[i] / max) * (h - 3) - 1.5;
		out.push(x.toFixed(2) + ',' + y.toFixed(2));
	}
	return out.join(' ');
}

function buildSpark(colorVar, values) {
	var w = 100, h = 30;
	var id = 'kw-spark-' + (++uid);

	var svg = svgEl('svg', {
		viewBox: '0 0 ' + w + ' ' + h,
		preserveAspectRatio: 'none'
	});

	var defs = svgEl('defs');
	var grad = svgEl('linearGradient', { id: id, x1: 0, y1: 0, x2: 0, y2: 1 });
	grad.appendChild(svgEl('stop', {
		offset: '0%', 'stop-color': colorVar, 'stop-opacity': '0.34'
	}));
	grad.appendChild(svgEl('stop', {
		offset: '100%', 'stop-color': colorVar, 'stop-opacity': '0.02'
	}));
	defs.appendChild(grad);
	svg.appendChild(defs);

	var pts = sparkPoints(values, w, h);

	var area = svgEl('polygon', {
		points: '0,' + h + ' ' + pts + ' ' + w + ',' + h,
		fill: 'url(#' + id + ')'
	});
	svg.appendChild(area);

	var line = svgEl('polyline', {
		points: pts,
		fill: 'none',
		stroke: colorVar,
		'stroke-width': '1.6',
		'stroke-linejoin': 'round',
		'stroke-linecap': 'round',
		'vector-effect': 'non-scaling-stroke'
	});
	svg.appendChild(line);

	return { svg: svg, area: area, line: line };
}

function updateSpark(holder, values) {
	if (!holder) return;
	var pts = sparkPoints(values, 100, 30);
	holder.line.setAttribute('points', pts);
	holder.area.setAttribute('points', '0,30 ' + pts + ' 100,30');
}

/* ─── 环形进度 ─────────────────────────────────────────────────────────────── */
function buildRing(cfg) {
	var size = 84;
	var svg = svgEl('svg', { viewBox: '0 0 ' + size + ' ' + size, width: size, height: size });

	svg.appendChild(svgEl('circle', {
		class: 'kw-ring-track',
		cx: size / 2, cy: size / 2, r: RING_R,
		'stroke-width': 7
	}));

	var fill = svgEl('circle', {
		class: 'kw-ring-fill',
		cx: size / 2, cy: size / 2, r: RING_R,
		'stroke-width': 7,
		stroke: cfg.color || 'var(--kw-brand)',
		'stroke-dasharray': RING_C.toFixed(2),
		'stroke-dashoffset': RING_C.toFixed(2)
	});
	svg.appendChild(fill);

	var valEl = E('div', { class: 'kw-ring-val kw-mono' }, cfg.value || '—');
	var center = E('div', { class: 'kw-ring-center' }, [valEl]);

	var graph = E('div', { class: 'kw-ring-graph' }, [svg, center]);

	return {
		el: E('div', { class: 'kw-card kw-ring' }, [
			graph,
			E('div', { class: 'kw-ring-label' }, cfg.label),
			E('div', { class: 'kw-ring-sub' }, cfg.sub || '')
		]),
		fill: fill,
		valEl: valEl,
		subEl: null
	};
}

function setRing(ring, pct, valueNode, color) {
	if (!ring) return;
	pct = Math.max(0, Math.min(100, Number(pct) || 0));
	ring.fill.setAttribute('stroke-dashoffset', (RING_C * (1 - pct / 100)).toFixed(2));
	if (color) ring.fill.setAttribute('stroke', color);
	if (valueNode != null)
		ring.valEl.innerHTML = valueNode;
}

/* ─── 慢变量：conntrack 计数（ACL 已授权这两条路径） ───────────────────────── */
function readSlow() {
	return Promise.all([
		L.resolveDefault(fs.read('/proc/sys/net/netfilter/nf_conntrack_count'), null),
		L.resolveDefault(fs.read('/proc/sys/net/netfilter/nf_conntrack_max'), null)
	]).then(function(r) {
		var c = parseInt(String(r[0] || '').trim(), 10);
		var m = parseInt(String(r[1] || '').trim(), 10);
		slowData.conn    = isNaN(c) ? null : c;
		slowData.connMax = isNaN(m) ? null : m;
		return slowData;
	}).catch(function() { return slowData; });
}

/* ─── 取数 ─────────────────────────────────────────────────────────────────── */
function fetchStats() {
	var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
	var tid  = ctrl ? setTimeout(function() { ctrl.abort(); }, 6000) : null;

	return fetch('/cgi-bin/luci/admin/tools/get_netdev_stats?fast=1',
			ctrl ? { signal: ctrl.signal, credentials: 'same-origin' } : { credentials: 'same-origin' })
		.then(function(r) { return r.json(); })
		.finally(function() { if (tid) clearTimeout(tid); })
		.catch(function() { return {}; });
}

function normalize(r) {
	r = r || {};
	var stats = (r.stats && typeof r.stats === 'object' && !Array.isArray(r.stats)) ? r.stats : {};
	return {
		stats:     stats,
		ip:        r.ip || 'N/A',
		status:    r.status || 'Disconnected',
		uptime:    Number(r.uptime)    || 0,
		cpuPct:    Number(r.cpu_pct)   || 0,
		cpuTemp:   (r.cpu_temp != null && r.cpu_temp !== '') ? Number(r.cpu_temp) : null,
		memPct:    Number(r.mem_pct)   || 0,
		memUsed:   Number(r.mem_used)  || 0,
		memTotal:  Number(r.mem_total) || 0,
		diskPct:   Number(r.disk_pct)  || 0,
		diskUsed:  Number(r.disk_used) || 0,
		diskTotal: Number(r.disk_total)|| 0,
		preferred: r.prefer_iface ? [r.prefer_iface] : []
	};
}

/* 由原始 stats 算出速率并推进历史 */
function computeRate(data, now) {
	var stats = data.stats;
	var iface = pickWan(stats, data.preferred);
	var cur   = stats[iface] || { rx: 0, tx: 0 };
	cur.rx = Number(cur.rx) || 0;
	cur.tx = Number(cur.tx) || 0;

	var dt = lastTime ? Math.max(0.2, (now - lastTime) / 1000) : 1;
	var old = prev[iface];

	var rxSpeed = 0, txSpeed = 0;
	if (old) {
		rxSpeed = Math.max(0, (cur.rx - old.rx) / dt);
		txSpeed = Math.max(0, (cur.tx - old.tx) / dt);
	}

	prev[iface] = { rx: cur.rx, tx: cur.tx };

	if (rxSpeed > peakRx) peakRx = rxSpeed;
	if (txSpeed > peakTx) peakTx = txSpeed;

	sparkRx.push(rxSpeed); if (sparkRx.length > SPARK_LEN) sparkRx.shift();
	sparkTx.push(txSpeed); if (sparkTx.length > SPARK_LEN) sparkTx.shift();

	var result = {
		iface:   iface,
		rxSpeed: rxSpeed,
		txSpeed: txSpeed,
		rxTotal: cur.rx,
		txTotal: cur.tx,
		trendRx: trendOf(rxSpeed, lastRx),
		trendTx: trendOf(txSpeed, lastTx),
		peakRx:  peakRx,
		peakTx:  peakTx
	};

	lastRx = rxSpeed;
	lastTx = txSpeed;
	return result;
}

/* ─── DOM 构建 ─────────────────────────────────────────────────────────────── */
function buildRateCard(kind, label, arrow) {
	var colorVar = kind === 'dl' ? 'var(--kw-dl)' : 'var(--kw-ul)';
	var spark = buildSpark(colorVar, kind === 'dl' ? sparkRx : sparkTx);

	var valEl = E('div', { class: 'kw-rate-val kw-mono' }, '0');
	var unitEl = E('div', { class: 'kw-rate-unit' }, 'bps');
	var trendEl = E('span', { class: 'kw-trend flat' }, '●');
	var peakEl = E('b', {}, '0 bps');

	var card = E('div', { class: 'kw-card kw-rate is-' + kind }, [
		E('div', { class: 'kw-rate-head' }, [
			E('span', { class: 'kw-rate-arrow' }, arrow),
			E('span', {}, label)
		]),
		E('div', { class: 'kw-rate-num' }, [valEl, unitEl, trendEl]),
		E('div', { class: 'kw-spark' }, [spark.svg]),
		E('div', { class: 'kw-rate-foot' }, [
			E('span', {}, [document.createTextNode('峰值 '), peakEl])
		])
	]);

	return { el: card, valEl: valEl, unitEl: unitEl, trendEl: trendEl, peakEl: peakEl, spark: spark };
}

function buildDashboard(data) {
	var now = Date.now();          /* 必须 var：文件在 'use strict' 下，裸赋值会抛 ReferenceError */
	var rate = computeRate(data, now);
	lastTime = now;
	lastData = data;

	/* ---- 速率 ---- */
	var dl = buildRateCard('dl', '下载', '↓');
	var ul = buildRateCard('ul', '上传', '↑');

	/* ---- 环形 ---- */
	var cpuRing = buildRing({ label: 'CPU', value: '—' });
	var tempRing = buildRing({ label: '温度', value: '—' });
	var memRing = buildRing({ label: '内存', value: '—' });
	var diskRing = buildRing({ label: '存储', value: '—' });
	var connRing = buildRing({ label: '连接数', value: '—' });

	/* ---- WAN 条 ---- */
	var badge = E('span', { class: 'kw-badge down' }, '未连接');
	var ipVal = E('span', { class: 'kw-wan-val kw-mono' }, data.ip);
	var ifVal = E('span', { class: 'kw-wan-val kw-mono' }, rate.iface || '—');
	var upVal = E('span', { class: 'kw-wan-val' }, formatUptime(data.uptime));

	var wanBar = E('div', { class: 'kw-card kw-wan' }, [
		badge,
		E('div', { class: 'kw-wan-item' }, [
			E('span', { class: 'kw-wan-key' }, '接口'), ifVal
		]),
		E('div', { class: 'kw-wan-item kw-wan-grow' }, [
			E('span', { class: 'kw-wan-key' }, 'IP'), ipVal
		]),
		E('div', { class: 'kw-wan-item' }, [
			E('span', { class: 'kw-wan-key' }, '运行'), upVal
		])
	]);

	/* ---- 总流量 ---- */
	var rxT = formatBytes(rate.rxTotal);
	var txT = formatBytes(rate.txTotal);
	var rxVal = E('div', { class: 'kw-total-val kw-mono' }, [
		document.createTextNode(rxT[0]),
		E('small', {}, rxT[1])
	]);
	var txVal = E('div', { class: 'kw-total-val kw-mono' }, [
		document.createTextNode(txT[0]),
		E('small', {}, txT[1])
	]);

	var totals = E('div', { class: 'kw-totals' }, [
		E('div', { class: 'kw-card kw-total is-dl' }, [
			E('div', { class: 'kw-total-key' }, [
				E('span', { class: 'kw-total-dot' }),
				E('span', {}, '累计下载')
			]),
			rxVal
		]),
		E('div', { class: 'kw-card kw-total is-ul' }, [
			E('div', { class: 'kw-total-key' }, [
				E('span', { class: 'kw-total-dot' }),
				E('span', {}, '累计上传')
			]),
			txVal
		])
	]);

	var root = E('div', { class: 'kw-wrap' }, [
		E('div', { class: 'kw-rates' }, [dl.el, ul.el]),
		E('div', { class: 'kw-rings' }, [cpuRing.el, tempRing.el, memRing.el, diskRing.el, connRing.el]),
		wanBar,
		totals
	]);

	refs = {
		dl: dl, ul: ul,
		cpuRing: cpuRing, tempRing: tempRing, memRing: memRing,
		diskRing: diskRing, connRing: connRing,
		badge: badge, ipVal: ipVal, ifVal: ifVal, upVal: upVal,
		rxVal: rxVal, txVal: txVal
	};

	applyAll(data, rate);
	return root;
}

/* ─── 定点更新（不重建 DOM，避免闪烁与曲线重置） ───────────────────────────── */
function applyAll(data, rate) {
	if (!refs) return;

	/* 速率 */
	var r1 = formatRate(rate.rxSpeed);
	var r2 = formatRate(rate.txSpeed);
	refs.dl.valEl.textContent = r1.num;
	refs.dl.unitEl.textContent = r1.unit;
	refs.ul.valEl.textContent = r2.num;
	refs.ul.unitEl.textContent = r2.unit;

	setTrend(refs.dl.trendEl, rate.trendRx);
	setTrend(refs.ul.trendEl, rate.trendTx);

	var p1 = formatRate(rate.peakRx);
	var p2 = formatRate(rate.peakTx);
	refs.dl.peakEl.textContent = p1.num + ' ' + p1.unit;
	refs.ul.peakEl.textContent = p2.num + ' ' + p2.unit;

	updateSpark(refs.dl.spark, sparkRx);
	updateSpark(refs.ul.spark, sparkTx);

	/* CPU */
	var cpuPct = Math.round(data.cpuPct);
	setRing(refs.cpuRing, cpuPct, cpuPct + '<small>%</small>', pctColor(cpuPct, 60, 85));

	/* 温度 */
	if (data.cpuTemp != null && !isNaN(data.cpuTemp)) {
		var t = Math.round(data.cpuTemp);
		var tp = Math.max(0, Math.min(100, (t / 100) * 100));
		var tc = t >= 70 ? 'var(--kw-bad)' : (t >= 55 ? 'var(--kw-warn)' : 'var(--kw-brand-2)');
		setRing(refs.tempRing, tp, String(t) + '<small>°C</small>', tc);
		refs.tempRing.el.querySelector('.kw-ring-sub').textContent =
			t >= 70 ? '偏高' : (t >= 55 ? '温热' : '正常');
	} else {
		setRing(refs.tempRing, 0, 'N/A', 'var(--kw-faint)');
		refs.tempRing.el.querySelector('.kw-ring-sub').textContent = '无传感器';
	}

	/* 内存 */
	var memPct = Math.round(data.memPct);
	setRing(refs.memRing, memPct, memPct + '<small>%</small>', pctColor(memPct, 75, 90));
	refs.memRing.el.querySelector('.kw-ring-sub').textContent =
		data.memUsed + ' / ' + data.memTotal + ' MB';

	/* 存储 */
	var diskPct = Math.round(data.diskPct);
	setRing(refs.diskRing, diskPct, diskPct + '<small>%</small>', pctColor(diskPct, 80, 92));
	refs.diskRing.el.querySelector('.kw-ring-sub').textContent =
		data.diskUsed + ' / ' + data.diskTotal + ' MB';

	/* 连接数 */
	var subEl = refs.connRing.el.querySelector('.kw-ring-sub');
	if (slowData.conn != null) {
		var cp = slowData.connMax > 0
			? Math.min(100, slowData.conn / slowData.connMax * 100) : 0;
		setRing(refs.connRing, cp,
			String(slowData.conn) + '<small></small>', pctColor(cp, 70, 88));
		subEl.textContent = slowData.connMax
			? '上限 ' + slowData.connMax : '当前活跃';
	} else {
		setRing(refs.connRing, 0, '—', 'var(--kw-faint)');
		subEl.textContent = '不可用';
	}

	/* WAN 条 */
	var up = (data.status === 'Connected');
	refs.badge.className = 'kw-badge ' + (up ? 'up' : 'down');
	refs.badge.textContent = up ? '已连接' : '未连接';
	refs.ipVal.textContent = data.ip || 'N/A';
	refs.ifVal.textContent = rate.iface || '—';
	refs.upVal.textContent = formatUptime(data.uptime);

	/* 累计流量 */
	var a = formatBytes(rate.rxTotal);
	var b = formatBytes(rate.txTotal);
	refs.rxVal.innerHTML = '';
	refs.rxVal.appendChild(document.createTextNode(a[0]));
	refs.rxVal.appendChild(E('small', {}, a[1]));

	refs.txVal.innerHTML = '';
	refs.txVal.appendChild(document.createTextNode(b[0]));
	refs.txVal.appendChild(E('small', {}, b[1]));
}

function setTrend(el, kind) {
	el.className = 'kw-trend ' + kind;
	el.textContent = kind === 'up' ? '▲' : (kind === 'down' ? '▼' : '●');
}

/* ─── 导出：index.js 认这三个字段 ──────────────────────────────────────────── */
return baseclass.extend({
	title: _('Status'),

	/* 内容每 2 秒就变，缓存只会让首屏闪一下旧数据 */
	disableCache: true,

	load: function() {
		return Promise.all([fetchStats(), readSlow()]).then(function(r) {
			/* 把「原始 JSON」原样递到 render，不在 load 里 normalize。
			   否则 render 再 normalize 一次会取不到 cpu_pct 这类下划线字段，
			   全部归零 —— 这是很容易踩的双重转换坑。 */
			return { raw: r[0] || {}, slow: r[1] || null };
		});
	},

	render: function(data) {
		/* 兼容两种入参：load 给的 {raw,slow}，或 index.js 缓存恢复时给的 null */
		var d = normalize(data && data.raw ? data.raw : data);
		var root = buildDashboard(d);

		if (!pollAdded) {
			pollAdded = true;

			poll.add(function() {
				return fetchStats().then(function(raw) {
					var d = normalize(raw);
					var now = Date.now();
					var rate = computeRate(d, now);
					lastTime = now;
					lastData = d;

					if (!refs)
						return;

					/* 实时部分每次都刷 */
					applyAll(d, rate);

					/* 慢变量隔几次刷一次，减少 rpcd 往返 */
					if (++slowTick >= SLOW_EVERY) {
						slowTick = 0;
						readSlow().then(function() {
							if (refs) applyAll(lastData, rate);
						});
					}
				}).catch(function() {});
			}, POLL_MS / 1000);
		}

		return root;
	}
});
