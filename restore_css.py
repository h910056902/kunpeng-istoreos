import paramiko

host = '192.168.66.1'
port = 22
user = 'root'
password = 'admin'

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

try:
    client.connect(host, port, user, password, timeout=10)

    commands = [
        'cp /www/luci-static/nradio/css/istore-theme.css.bak /www/luci-static/nradio/css/istore-theme.css',
        'grep "backdrop-filter" /www/luci-static/nradio/css/istore-theme.css',
        'rm -rf /tmp/luci-*',
    ]

    for cmd in commands:
        stdin, stdout, stderr = client.exec_command(cmd)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode().strip()
        err = stderr.read().decode().strip()
        print(f'=== CMD: {cmd} ===')
        if out:
            print(f'STDOUT: {out}')
        if err:
            print(f'STDERR: {err}')
        print(f'EXIT_CODE: {exit_code}')
        print()

    print('=== VERIFICATION ===')
    print('If grep exit code is 1 and no matches shown, backdrop-filter is gone.')
    print('Cache cleared if no errors from rm command.')

finally:
    client.close()
