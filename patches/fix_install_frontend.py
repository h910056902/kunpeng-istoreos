# -*- coding: utf-8 -*-
"""
修复「点击安装没有实际安装效果」— 前端部分
文件: /usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm
  1. 新增 aurora_toast 提示 + 样式
  2. 重写 aurora_online_install: 真实返回码处理 + 轮询任务状态 + 失败显示原因 + 重试按钮
"""
import paramiko, datetime

HOST = '192.168.66.1'
USER = 'root'
PWD = __import__('os').environ.get('ROUTER_PW', 'admin')  # 路由器密码, 建议用环境变量 ROUTER_PW 传入
TPL = '/usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PWD, timeout=15)
sftp = c.open_sftp()

with sftp.open(TPL, 'r') as f:
    src = f.read().decode('utf-8')
orig = src
ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
with sftp.open(TPL + '.bak-fixinstall-' + ts, 'w') as f:
    f.write(src)
print('[backup] %s.bak-fixinstall-%s' % (TPL, ts))

# ---------- 1) toast 样式 ----------
ANCHOR_CSS = '.aurora-empty-ico{display:block;font-size:34px;color:rgba(139,92,246,.6);margin-bottom:10px}'
assert ANCHOR_CSS in src, 'css anchor not found'
TOAST_CSS = ANCHOR_CSS + """
.aurora-toast{position:fixed;left:50%;bottom:38px;transform:translateX(-50%) translateY(20px);z-index:99999;max-width:80%;padding:12px 20px;border-radius:12px;font-size:13px;line-height:1.5;color:#eaf6ff;background:rgba(10,16,28,.96);border:1px solid rgba(34,211,238,.35);box-shadow:0 18px 50px -10px rgba(0,0,0,.6),0 0 24px -8px rgba(34,211,238,.3);backdrop-filter:blur(20px);opacity:0;transition:opacity .22s ease,transform .22s ease;pointer-events:none}
.aurora-toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
.aurora-toast.err{border-color:rgba(248,113,113,.45);box-shadow:0 18px 50px -10px rgba(0,0,0,.6),0 0 24px -8px rgba(248,113,113,.3)}
.aurora-toast.ok{border-color:rgba(52,211,153,.45);box-shadow:0 18px 50px -10px rgba(0,0,0,.6),0 0 24px -8px rgba(52,211,153,.3)}
.aurora-progress{display:block;margin-top:5px;font-size:10.5px;color:var(--a-muted);max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"""
src = src.replace(ANCHOR_CSS, TOAST_CSS, 1)
print('  * +toast css')

# ---------- 2) 重写安装流程 ----------
OLD_INSTALL = """function aurora_online_install(pkg){
    if (ONLINE_INSTALLING[pkg]) return;
    ONLINE_INSTALLING[pkg] = true;
    var card = $('.app_online .aurora-card[data-pkg="'+pkg+'"]');
    card.find('.aurora-card-actions').html('<button class="aurora-btn is-open" disabled>安装中…</button>');
    $.post('<%=url("nradioadv/system/appcenter/online_install")%>', {pkg: pkg, token: '<%=token%>'}, function(){
        var tries = 0;
        var timer = setInterval(function(){
            tries++;
            $.getJSON('<%=url("nradioadv/system/appcenter/online_list")%>', function(res){
                var list = (res && res.list) || [];
                window.AURORA_ONLINE_LIST = list;
                var done = false;
                $.each(list, function(i,d){ if (d.pkg===pkg && d.installed) done = true; });
                if (done || tries > 40) {
                    clearInterval(timer);
                    delete ONLINE_INSTALLING[pkg];
                    aurora_online_render(list);
                }
            }).fail(function(){ if (tries > 40) { clearInterval(timer); delete ONLINE_INSTALLING[pkg]; } });
        }, 3000);
    }, 'json').fail(function(){ delete ONLINE_INSTALLING[pkg]; aurora_online_load(true); });
}"""

assert OLD_INSTALL in src, 'install fn not found'

NEW_INSTALL = r"""/* ---- toast ---- */
function aurora_toast(msg, kind, ms){
    var box = $('#aurora_toast');
    if (!box.length) { box = $('<div id="aurora_toast" class="aurora-toast"></div>').appendTo('body'); }
    box.removeClass('show err ok').addClass(kind === 'err' ? 'err' : (kind === 'ok' ? 'ok' : ''));
    box.html(msg);
    setTimeout(function(){ box.addClass('show'); }, 10);
    clearTimeout(box.data('t'));
    box.data('t', setTimeout(function(){ box.removeClass('show'); }, ms || (kind === 'err' ? 7000 : 3200)));
}
/* ---- 解析 opkg 日志, 给出人话错误 ---- */
function aurora_install_error(log){
    log = log || '';
    var m = log.match(/cannot find dependency ([\w\-\.\+]+) for/);
    if (m) return '缺少依赖 <b>'+aurora_escape(m[1])+'</b>，当前架构下软件源中没有该包';
    if (/incompatible with the architectures configured/.test(log)) return '该软件与当前架构(aarch64_cortex-a53)不兼容';
    m = log.match(/Unknown package '([\w\-\.\+]+)'/);
    if (m) return '软件源中找不到 <b>'+aurora_escape(m[1])+'</b>';
    if (/no space left on device/i.test(log)) return '存储空间不足';
    if (/Failed to download|wget: .* (404|Failed|unreachable)/i.test(log)) return '下载失败，请检查网络';
    var lines = log.split('\n').filter(function(l){ return l.indexOf(' * ') === 0; });
    if (lines.length) return aurora_escape(lines[0].replace(/^ \* /, ''));
    return '未知错误';
}
/* ---- 设置单张卡片的操作区 ---- */
function aurora_set_card_btn(pkg, html){
    var card = $('.app_online .aurora-card[data-pkg="'+pkg+'"]');
    if (card.length) card.find('.aurora-card-actions').html(html);
}
function aurora_btn_installing(pkg, tip){
    aurora_set_card_btn(pkg, '<button class="aurora-btn is-open" disabled>安装中…</button>' +
        (tip ? '<span class="aurora-progress" title="'+aurora_escape(tip)+'">'+aurora_escape(tip)+'</span>' : ''));
}
function aurora_btn_retry(pkg){
    aurora_set_card_btn(pkg, '<button class="aurora-btn is-install" onclick="aurora_online_install(\''+aurora_escape(pkg)+'\')">重试</button>');
}
/* ---- 轮询任务状态 ---- */
var AURORA_POLL_TIMER = null;
function aurora_poll_install(pkg, tries){
    tries = tries || 0;
    clearTimeout(AURORA_POLL_TIMER);
    if (tries > 240) {                       /* 约 12 分钟 */
        delete ONLINE_INSTALLING[pkg];
        aurora_btn_retry(pkg);
        aurora_toast('安装超时，请重试或查看系统日志', 'err');
        return;
    }
    AURORA_POLL_TIMER = setTimeout(function(){
        $.getJSON('<%=url("nradioadv/system/appcenter/online_install_status")%>', function(st){
            if (st && st.running) {
                var lines = String(st.log||'').split('\n').filter(function(l){ return $.trim(l); });
                var last = lines[lines.length-1] || '';
                var tip = '';
                var dm = last.match(/Downloading (\S+)/);
                if (dm) tip = '下载 ' + dm[1].split('/').pop();
                else if (/Installing ([\w\-\.\+]+)/.test(last)) tip = '安装 ' + (last.match(/Installing ([\w\-\.\+]+)/)||[])[1];
                else if (/Update feeds index|Fetch feed list/.test(last)) tip = '更新软件源…';
                aurora_btn_installing(pkg, tip);
                aurora_poll_install(pkg, tries + 1);
                return;
            }
            delete ONLINE_INSTALLING[pkg];
            var ok = st && (String(st.exit_code) === '0');
            if (ok) {
                aurora_toast('安装完成', 'ok');
                aurora_online_load(true);
                if (typeof aurora_load_all === 'function') { try { aurora_load_all(true); } catch(e){} }
                if (typeof get_app_list === 'function') { try { get_app_list(); } catch(e){} }
            } else {
                aurora_btn_retry(pkg);
                aurora_toast('安装失败：' + aurora_install_error(st && st.log), 'err');
            }
        }).fail(function(){
            aurora_poll_install(pkg, tries + 1);
        });
    }, 3000);
}
/* ---- 安装入口 ---- */
function aurora_online_install(pkg){
    if (ONLINE_INSTALLING[pkg]) return;
    ONLINE_INSTALLING[pkg] = true;
    aurora_btn_installing(pkg, '提交中…');
    $.post('<%=url("nradioadv/system/appcenter/online_install")%>', {pkg: pkg, token: '<%=token%>'}, function(res){
        if (res && res.code === 0) {
            aurora_poll_install(pkg, 0);
        } else {
            delete ONLINE_INSTALLING[pkg];
            aurora_btn_retry(pkg);
            aurora_toast('无法启动安装：' + aurora_escape((res && res.msg) || '未知错误'), 'err');
        }
    }, 'json').fail(function(){
        delete ONLINE_INSTALLING[pkg];
        aurora_btn_retry(pkg);
        aurora_toast('安装请求失败，请检查网络后重试', 'err');
    });
}"""

src = src.replace(OLD_INSTALL, NEW_INSTALL, 1)
print('  * aurora_online_install rewritten (+toast/error/poll/retry)')

with sftp.open(TPL, 'w') as f:
    f.write(src)
print('[written] %s (%d -> %d bytes)' % (TPL, len(orig), len(src)))

# 清缓存
_, o, _ = c.exec_command('rm -rf /tmp/luci-*cache* /tmp/luci-modulecache 2>/dev/null; echo CLEARED', timeout=20)
print('[cache] ' + o.read().decode().strip())

sftp.close()
c.close()
