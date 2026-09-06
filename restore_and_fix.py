"""
一键恢复首页 + 安全叠加 v5 玻璃效果
运行: python restore_and_fix.py
"""
import paramiko, os, threading, socketserver, http.server

HOST = '192.168.66.1'
PORT = 22
USER = 'root'
PASS = 'admin'

# ========== Step 1: Restore original istore-theme.css ==========
client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(HOST, PORT, USER, PASS, timeout=15)

print("[1/4] Restoring original istore-theme.css from backup...")
client.exec_command('cp /www/luci-static/nradio/css/istore-theme.css.bak /www/luci-static/nradio/css/istore-theme.css', timeout=10)

print("[2/4] Cleaning up bad v5 files...")
client.exec_command('rm -f /www/luci-static/nradio/css/liquid-glass-v5.css /www/luci-static/nradio/css/liquid-glass-v6.css', timeout=10)

print("[3/4] Removing v5/v6 CSS links from header...")
# Fix the REAL LuCI template
client.exec_command("sed -i '/liquid-glass-v5/d' /usr/lib/lua/luci/view/themes/nradio/header.htm", timeout=10)
client.exec_command("sed -i '/liquid-glass-v6/d' /usr/lib/lua/luci/view/themes/nradio/header.htm", timeout=10)
client.exec_command("sed -i '/adv-theme\\.css/d' /usr/lib/lua/luci/view/themes/nradio/header.htm", timeout=10)
# Fix the static copy too
client.exec_command("sed -i '/liquid-glass/d' /www/luci-static/nradio/header.htm", timeout=10)
client.exec_command("sed -i '/adv-theme\\.css/d' /www/luci-static/nradio/header.htm", timeout=10)

print("[4/4] Clearing LuCI cache...")
client.exec_command('rm -rf /tmp/luci-*', timeout=5)

client.close()
print("\n✅ 首页已恢复！请 Ctrl+F5 刷新路由器页面。")
print("   原版 istore-theme.css 已从备份恢复。")
print("   v5/v6 CSS 链接已从 header.htm 移除。")
print("   LuCI 缓存已清除。")
