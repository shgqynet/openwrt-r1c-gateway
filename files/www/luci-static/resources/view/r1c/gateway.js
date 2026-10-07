'use strict';
'require view';

// R1C 工业网关 —— LuCI 菜单入口视图。
//
// 只做一件事：把本地应急管理页 /cgi-bin/r1c 嵌进 LuCI。
// ⚠️ 为什么不用 LuCI 表单重写一遍那个页面：
//   * 那个页面是纯 busybox ash 的 CGI，隧道断了照样能开（这是它的核心价值）；
//     改成 LuCI 视图就要依赖 rpcd/ubus/JS 全链路，任一环断了现场就改不了 WiFi。
//   * 固件里没有 lua 解释器，template action 也用不了。
// 所以这里是 iframe + 一个"新标签页打开"的兜底链接（iframe 被浏览器策略挡住时还能用）。

return view.extend({
	render: function() {
		var url = '/cgi-bin/r1c';

		var frame = E('iframe', {
			'id': 'r1c-frame',
			'src': url,
			'style': 'width:100%;height:calc(100vh - 250px);min-height:820px;border:0;background:#fff'
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('R1C 工业远程网关') ]),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('本地应急管理页：隧道断了也能用 —— 改 WiFi 上行、看运行状态、下发站点配置。'),
				E('br'),
				_('若下方区域空白，请'),
				E('a', { 'href': url, 'target': '_blank', 'rel': 'noopener' }, [ _('点此在新标签页打开') ]),
				_('。')
			]),
			frame
		]);
	}
});
