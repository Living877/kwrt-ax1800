'use strict';
'require baseclass';

/* ═════════════════════════════════════════════════════════════════════════════
   概览页恢复上游 LuCI 原版布局 —— 摘掉 Kwrt 加的实时带宽卡

   原理（view/status/index.js 的 poll_status）：
     只有当 render() 返回非 null 时，才会执行
         containers[i].parentNode.style.display = '';
     否则外层的 .cbi-section 永远保持 display:none。
     所以这里让 render 返回 null，带宽卡整张不出现，且不用改任何上游代码。

   load 返回一个已 resolve 的 Promise，避免被 skip 掉而留下占位。
   ═════════════════════════════════════════════════════════════════════════════ */

return baseclass.extend({
	title: 'Bandwidth',

	load: function() {
		return Promise.resolve(null);
	},

	render: function() {
		return null;
	}
});
