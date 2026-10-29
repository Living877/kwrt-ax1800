'use strict';
'require baseclass';

/* 摘掉 Kwrt 重写的端口卡（26_ports），端口状态改由官方的 29_ports 渲染。
   两个模块同时存在会出两张端口卡，这里让 26_ports 直接失败退出，
   view/status/index.js 会把 failed 的卡片保持隐藏。 */

return baseclass.extend({
	title: 'Ports',

	load: function() {
		return Promise.reject();
	},

	render: function() {
		return null;
	}
});
