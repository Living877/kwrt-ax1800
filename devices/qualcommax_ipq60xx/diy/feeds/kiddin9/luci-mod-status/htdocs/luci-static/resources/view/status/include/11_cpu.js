'use strict';
'require baseclass';

/* 摘掉 Kwrt 独有的 CPU 卡（官方没有 11_cpu 这个模块，CPU 信息在 10_system 里）。
   render 返回 null 时，view/status/index.js 不会把卡片 display 设回 ''，
   于是整张卡保持隐藏，不需要改动上游任何代码。 */

return baseclass.extend({
	title: 'CPU',

	load: function() {
		return Promise.reject();
	},

	render: function() {
		return null;
	}
});
