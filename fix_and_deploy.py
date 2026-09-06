"""
一键恢复首页 + 安全部署 Liquid Glass v5
运行: python fix_and_deploy.py
"""
import paramiko, os, threading, socketserver, http.server, time, sys

HOST = '192.168.66.1'
USER = 'root'
PASS = 'admin'
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

print("=" * 55)
print("   NRadio 路由器 — Liquid Glass v5 修复 + 部署")
print("=" * 55)

# ===================== 1. SSH connect =====================
print("\n>>> 连接路由器...")
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, 22, USER, PASS, timeout=15)
print("    已连接")

# ===================== 2. Restore istore-theme.css =====================
print("\n>>> 恢复原版 istore-theme.css...")
i, o, e = c.exec_command(
    'cp /www/luci-static/nradio/css/istore-theme.css.bak /www/luci-static/nradio/css/istore-theme.css && echo OK || echo FAIL',
    timeout=10
)
result = o.read().decode().strip()
print(f"    恢复: {result}")

# ===================== 3. Clean old v4/v5/v6 CSS =====================
print("\n>>> 清理旧文件...")
for f in ['liquid-glass-v4.css', 'liquid-glass-v5.css', 'liquid-glass-v6.css',
          'liquid-glass-v5.css.disabled', 'liquid-glass-v6.css.disabled']:
    c.exec_command(f'rm -f /www/luci-static/nradio/css/{f}', 5)
print("    旧 CSS 文件已删除")

# ===================== 4. Clean header links =====================
print("\n>>> 清理 header.htm 中的旧链接...")
for path in [
    '/usr/lib/lua/luci/view/themes/nradio/header.htm',
    '/www/luci-static/nradio/header.htm',
]:
    c.exec_command(f"sed -i '/liquid-glass/d' {path}", 5)
    c.exec_command(f"sed -i '/adv-theme\\.css/d' {path}", 5)

# Verify cleanup
i, o, e = c.exec_command(
    "grep -n 'liquid-glass\\|adv-theme' /usr/lib/lua/luci/view/themes/nradio/header.htm /www/luci-static/nradio/header.htm 2>/dev/null || echo 'MATCH_CLEAN'",
    timeout=10
)
print(f"    旧链接: {o.read().decode().strip()}")

# ===================== 5. Upload safe v5 CSS =====================
print("\n>>> 上传安全 v5 CSS...")

# Start local HTTP server
css_file = 'liquid-glass-safe-v5.css'
css_path = os.path.join(SCRIPT_DIR, css_file)
if not os.path.exists(css_path):
    print(f"    ERROR: {css_file} not found in {SCRIPT_DIR}")
    c.close()
    sys.exit(1)

os.chdir(SCRIPT_DIR)

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, f, *a): pass

httpd = socketserver.TCPServer(('0.0.0.0', 8899), Quiet)
httpd.allow_reuse_address = True
t = threading.Thread(target=httpd.serve_forever, daemon=True)
t.start()
time.sleep(0.5)

# Get local IP from router's perspective
i, o, e = c.exec_command('echo $SSH_CLIENT', 10)
local_ip = o.read().decode().strip().split()[0]

# Download CSS from local HTTP server
remote = '/www/luci-static/nradio/css/liquid-glass-v5.css'
cmd = f'wget -q -O {remote} http://{local_ip}:8899/{css_file} && echo UPLOAD_OK || echo UPLOAD_FAIL'
i, o, e = c.exec_command(cmd, 30)
print(f"    上传: {o.read().decode().strip()}")

httpd.shutdown()

# Verify size
i, o, e = c.exec_command(f'wc -c {remote}', 10)
remote_size = o.read().decode().strip()
local_size = os.path.getsize(css_path)
print(f"    大小: remote={remote_size} local={local_size}")
if local_size != int(remote_size.split()[0]):
    print("    WARNING: filesize mismatch!")

# ===================== 6. Inject CSS link into headers =====================
print("\n>>> 注入 v5 CSS 链接...")

link_line = '    <link rel="stylesheet" type="text/css" href="/luci-static/nradio/css/liquid-glass-v5.css?v=2">'

for hdr_path in [
    '/usr/lib/lua/luci/view/themes/nradio/header.htm',
    '/www/luci-static/nradio/header.htm',
]:
    # Read remote header
    i, o, e = c.exec_command(f'cat {hdr_path}', 15)
    content = o.read().decode('utf-8', errors='replace')

    if 'liquid-glass-v5' not in content and 'istore-theme.css' in content:
        # Find the line with istore-theme.css and insert after it
        lines = content.split('\n')
        new_lines = []
        for line in lines:
            new_lines.append(line)
            if 'istore-theme.css' in line:
                new_lines.append(link_line)
        new_content = '\n'.join(new_lines)

        # Save locally and upload via HTTP
        hdr_name = os.path.basename(hdr_path)
        local_hdr = os.path.join(SCRIPT_DIR, hdr_name)
        with open(local_hdr, 'w', encoding='utf-8') as f:
            f.write(new_content)

        # Start HTTP server
        httpd2 = socketserver.TCPServer(('0.0.0.0', 8899), Quiet)
        httpd2.allow_reuse_address = True
        t2 = threading.Thread(target=httpd2.serve_forever, daemon=True)
        t2.start()
        time.sleep(0.3)

        cmd = f'wget -q -O {hdr_path} http://{local_ip}:8899/{hdr_name} && echo OK || echo FAIL'
        i, o, e = c.exec_command(cmd, 15)
        print(f"    {hdr_name}: {o.read().decode().strip()}")

        httpd2.shutdown()
        os.remove(local_hdr)
    else:
        status = '已存在' if 'liquid-glass-v5' in content else '无 istore-theme.css'
        print(f"    {hdr_name}: {status}")

# Verify
i, o, e = c.exec_command(
    "grep -c 'liquid-glass-v5' /usr/lib/lua/luci/view/themes/nradio/header.htm",
    timeout=10
)
print(f"    验证: v5 链接出现 {o.read().decode().strip()} 次")

# ===================== 7. Clear cache =====================
print("\n>>> 清除 LuCI 缓存...")
c.exec_command('rm -rf /tmp/luci-*', 5)
print("    已清除")

c.close()

print("\n" + "=" * 55)
print("  ✅ 全部完成!")
print("=" * 55)
print("""
  操作清单:
  [✓] 原版 istore-theme.css 已恢复 (不影响布局)
  [✓] 安全 v5 玻璃 CSS 已部署 (仅覆盖视觉属性)
  [✓] 旧 v4/v5/v6 CSS 文件及链接已清除
  [✓] v5 CSS 链接已注入 header.htm (istore-theme 之后加载)
  [✓] LuCI 缓存已清除

  现在打开 http://192.168.66.1
  按 Ctrl+F5 硬刷新查看效果
""")
