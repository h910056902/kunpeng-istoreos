"""
一键修复 + 安全部署 v5 玻璃效果
运行: python fix_all.py
"""
import paramiko, os, threading, socketserver, http.server, time

HOST = '192.168.66.1'
USER = 'root'
PASS = 'admin'

print("=" * 50)
print("  NRadio 路由器 Liquid Glass v5 一键修复/部署")
print("=" * 50)

# ===================== Step 1: SSH connect =====================
print("\n[1] 连接路由器...")
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PASS, timeout=15)
print("   已连接")

# ===================== Step 2: restore original istore-theme.css =====================
print("\n[2] 恢复原版 istore-theme.css ...")
c.exec_command('cp /www/luci-static/nradio/css/istore-theme.css.bak /www/luci-static/nradio/css/istore-theme.css', 10)
print("   已恢复")

# ===================== Step 3: clean up old v5/v6 =====================
print("\n[3] 清理旧文件 ...")
for f in ['liquid-glass-v5.css', 'liquid-glass-v6.css', 'liquid-glass-v4.css']:
    c.exec_command(f'rm -f /www/luci-static/nradio/css/{f}', 5)
print("   已清理")

# ===================== Step 4: clean header links =====================
print("\n[4] 清理 header.htm CSS 链接 ...")
for path in [
    '/usr/lib/lua/luci/view/themes/nradio/header.htm',
    '/www/luci-static/nradio/header.htm',
]:
    c.exec_command(f"sed -i '/liquid-glass/d' {path}", 5)
    c.exec_command(f"sed -i '/adv-theme\\.css/d' {path}", 5)
print("   已清理")

# ===================== Step 5: upload safe v5 CSS =====================
print("\n[5] 上传安全 v5 玻璃 CSS ...")

# Get local IP
i, o, e = c.exec_command('echo $SSH_CLIENT', 10)
local_ip = o.read().decode().strip().split()[0]

# Start HTTP server
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
os.chdir(SCRIPT_DIR)

class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, f, *a): pass

httpd = socketserver.TCPServer(('0.0.0.0', 8899), Q)
t = threading.Thread(target=httpd.serve_forever, daemon=True)
t.start()
time.sleep(0.5)

# Upload
cmd = f'wget -q -O /www/luci-static/nradio/css/liquid-glass-v5.css http://{local_ip}:8899/liquid-glass-safe-v5.css && echo UPLOAD_OK || echo FAIL'
i, o, e = c.exec_command(cmd, 30)
result = o.read().decode().strip()
print(f"   上传结果: {result}")

httpd.shutdown()

# Verify
i, o, e = c.exec_command('wc -c /www/luci-static/nradio/css/liquid-glass-v5.css', 10)
print(f"   文件大小: {o.read().decode().strip()}")

# ===================== Step 6: inject CSS link =====================
print("\n[6] 注入 v5 CSS 链接到 LuCI 模板 ...")

# Read current template
i, o, e = c.exec_command('cat /usr/lib/lua/luci/view/themes/nradio/header.htm', 15)
content = o.read().decode('utf-8')

# Insert after istore-theme.css line
if 'istore-theme.css' in content and 'liquid-glass-v5' not in content:
    marker = 'istore-theme.css'
    idx = content.index(marker) + len(marker)
    end_of_line = content.index('\n', idx)
    new_link = '    <link rel="stylesheet" type="text/css" href="/luci-static/nradio/css/liquid-glass-v5.css?v=2">'
    content = content[:end_of_line+1] + new_link + '\n' + content[end_of_line+1:]

    # Write back via cat (small file, safe for heredoc)
    import base64
    encoded = base64.b64encode(content.encode('utf-8')).decode('ascii')
    c.exec_command(f"echo '{encoded}' | base64 -d > /usr/lib/lua/luci/view/themes/nradio/header.htm", 10)
    print("   v5 链接已注入")
else:
    print("   链接已存在或 istore-theme.css 未找到")

# ===================== Step 7: clear cache =====================
print("\n[7] 清除 LuCI 缓存 ...")
c.exec_command('rm -rf /tmp/luci-*', 5)
print("   已清除")

c.close()

print("\n" + "=" * 50)
print("  ✅ 修复完成!")
print("=" * 50)
print()
print("  1. 原版 istore-theme.css 已恢复")
print("  2. 安全 v5 玻璃 CSS 已部署 (不影响布局)")
print("  3. 旧 v4/v5/v6 CSS 已清理")
print("  4. LuCI 缓存已清除")
print()
print("  现在打开 http://192.168.66.1  Ctrl+F5 刷新")
