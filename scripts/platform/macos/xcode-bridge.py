#!/usr/bin/env python3
"""Authenticated Xcode bridge. Authentication is not a sandbox for project scripts."""
import argparse
import base64
import hmac
import http.server
import json
import os
import pathlib
import pwd
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

REQUEST_LIMIT = 1024 * 1024
OUTPUT_LIMIT = 8 * 1024 * 1024
SDK_NAMES = {'macosx', 'iphoneos', 'iphonesimulator', 'appletvos', 'appletvsimulator',
             'watchos', 'watchsimulator', 'xros', 'xrsimulator'}


class Rejected(ValueError):
    pass


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Rejected('duplicate JSON member')
        result[key] = value
    return result


def decode_json(raw):
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=no_duplicates,
                          parse_constant=lambda _: (_ for _ in ()).throw(Rejected('invalid JSON number')))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Rejected('invalid JSON') from error


def clean_absolute(value):
    if not isinstance(value, str) or not value.startswith('/') or '\x00' in value:
        raise Rejected('expected absolute path')
    if '..' in pathlib.PurePosixPath(value).parts or '\\' in value:
        raise Rejected('path traversal is not allowed')
    return os.path.normpath(value)


def beneath(path, root):
    return path == root or path.startswith(root.rstrip('/') + '/')


class MountMap:
    def __init__(self, pairs):
        self.pairs = []
        for host, container in pairs:
            host = os.path.realpath(clean_absolute(host))
            container = clean_absolute(container)
            if not os.path.isdir(host) or container == '/':
                raise Rejected('mount roots must be existing directories and non-root container paths')
            if any(container == other[1] for other in self.pairs):
                raise Rejected('duplicate container mount root')
            self.pairs.append((host, container))
        self.pairs.sort(key=lambda pair: len(pair[1]), reverse=True)

    def translate(self, value, cwd=None, directory=False):
        if not isinstance(value, str) or not value or '\x00' in value or '\\' in value:
            raise Rejected('invalid path')
        if '..' in pathlib.PurePosixPath(value).parts:
            raise Rejected('path traversal is not allowed')
        if not value.startswith('/'):
            if cwd is None:
                raise Rejected('relative path requires mapped cwd')
            value = os.path.join(cwd, value)
        value = clean_absolute(value)
        # Container destinations are authoritative, including nested mounts.
        selected = next(((host, container) for host, container in self.pairs
                         if beneath(value, container)), None)
        if selected:
            root, container = selected
            candidate = root + value[len(container):]
        else:
            selected = next(((host, container) for host, container in
                             sorted(self.pairs, key=lambda pair: len(pair[0]), reverse=True)
                             if beneath(value, host)), None)
            if selected is None:
                raise Rejected('path is outside mounted roots')
            root, _ = selected
            candidate = value
        real = os.path.realpath(candidate)
        if not beneath(real, root):
            raise Rejected('symlink escapes mounted root')
        if directory and not os.path.isdir(real):
            raise Rejected('cwd must be an existing directory')
        return real


def plain_value(value):
    if not value or value.startswith('-') or any(ch in value for ch in ('\x00', '\n', '\r', '=')):
        raise Rejected('invalid option value')
    return value


def validate_command(command, args, cwd, mounts, tools):
    if command not in ('xcodebuild', 'xcrun', 'simctl'):
        raise Rejected('unsupported command')
    if not isinstance(args, list) or len(args) > 256:
        raise Rejected('invalid argument count')
    if any(not isinstance(arg, str) or len(arg.encode('utf-8')) > 8192 or '\x00' in arg for arg in args):
        raise Rejected('invalid argument')
    clean_absolute(cwd)
    metadata = command == 'xcodebuild' and args in (['-version'], ['-showsdks'], ['-help'])
    if command == 'xcrun' and args != [] and args[0] != 'simctl':
        query_args = list(args)
        if len(query_args) >= 2 and query_args[0] == '--sdk':
            if query_args[1] not in SDK_NAMES:
                raise Rejected('unsupported SDK')
            query_args = query_args[2:]
        if len(query_args) != 1 or query_args[0] not in (
                '--version', '--show-sdk-path', '--show-sdk-version',
                '--show-sdk-build-version', '--show-sdk-platform-path'):
            raise Rejected('unsupported xcrun query or executable')
        metadata = True
    if metadata:
        workdir = mounts.translate(cwd, directory=True) if mounts.pairs else '/'
        return [tools[command], *args], workdir
    workdir = mounts.translate(cwd, directory=True)
    if command in ('xcrun', 'simctl'):
        simargs = args[1:] if command == 'xcrun' and args[:1] == ['simctl'] else args
        if command == 'xcrun' and args[:1] != ['simctl']:
            raise Rejected('only xcrun simctl is allowed')
        translated = validate_simctl(simargs, cwd, mounts)
        return [tools['xcrun'], 'simctl', *translated], workdir
    path_options = {'-project', '-workspace', '-derivedDataPath', '-resultBundlePath',
                    '-archivePath', '-exportPath', '-exportArchive', '-exportOptionsPlist',
                    '-xcconfig', '-testProductsPath', '-testPlanPath'}
    # Export configuration and xcconfig can redirect execution/output beyond the mount map.
    forbidden = {'-exportArchive', '-exportOptionsPlist', '-xcconfig'}
    text_options = {'-scheme', '-target', '-configuration', '-testPlan'}
    numeric_options = {'-jobs', '-parallel-testing-worker-count', '-maximum-concurrent-test-simulator-destinations'}
    flags = {'-list', '-json', '-showBuildSettings', '-showdestinations', '-showTestPlans',
             '-quiet', '-verbose', '-disableAutomaticPackageResolution', '-skipPackageUpdates',
             '-enableCodeCoverage'}
    actions = {'build', 'test', 'clean', 'analyze', 'archive', 'build-for-testing', 'test-without-building'}
    result = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in forbidden:
            raise Rejected('unsupported Xcode option')
        if arg in actions or arg in flags:
            if arg == '-enableCodeCoverage':
                if index + 1 >= len(args) or args[index + 1] not in ('YES', 'NO'):
                    raise Rejected('invalid coverage value')
                result.extend([arg, args[index + 1]])
                index += 2
                continue
            result.append(arg)
            index += 1
            continue
        if arg in path_options | text_options | numeric_options | {'-sdk', '-destination', '-only-testing', '-skip-testing'}:
            if index + 1 >= len(args):
                raise Rejected('missing option value')
            value = args[index + 1]
            if arg in path_options:
                value = mounts.translate(value, cwd)
            elif arg == '-sdk':
                if value not in SDK_NAMES:
                    raise Rejected('unsupported SDK')
            elif arg in numeric_options:
                if not value.isascii() or not value.isdigit() or not 1 <= int(value) <= 64:
                    raise Rejected('invalid parallelism')
            elif arg == '-destination':
                fields = value.split(',')
                if not fields or any('=' not in field or field.split('=', 1)[0] not in
                                     ('platform', 'name', 'id', 'OS', 'arch', 'variant') or
                                     not field.split('=', 1)[1] for field in fields):
                    raise Rejected('invalid destination')
                if any(ch in value for ch in ('\n', '\r')):
                    raise Rejected('invalid destination')
            else:
                plain_value(value)
            result.extend([arg, value])
            index += 2
            continue
        raise Rejected('unsupported Xcode option, action or build setting')
    if '-derivedDataPath' not in args:
        result.extend(['-derivedDataPath', mounts.translate('.codexshell-derived-data', cwd)])
    if 'archive' in args and '-archivePath' not in args:
        result.extend(['-archivePath', mounts.translate('.codexshell-build.xcarchive', cwd)])
    return [tools['xcodebuild'], *result], workdir


def validate_simctl(args, cwd, mounts):
    if not args:
        raise Rejected('missing simctl subcommand')
    subcommand, rest = args[0], args[1:]
    if subcommand == 'list':
        if any(value not in ('devices', 'devicetypes', 'runtimes', 'pairs', 'available', '-j', '--json') for value in rest):
            raise Rejected('unsupported simctl list option')
        return args
    counts = {'boot': (1, 1), 'shutdown': (1, 1), 'bootstatus': (1, 2), 'get_app_container': (2, 3)}
    if subcommand in counts:
        low, high = counts[subcommand]
        if not low <= len(rest) <= high:
            raise Rejected('invalid simctl argument count')
        for value in rest:
            if value == '-b' and subcommand == 'bootstatus':
                continue
            plain_value(value)
        if subcommand == 'bootstatus' and len(rest) == 2 and rest[1] != '-b':
            raise Rejected('unsupported bootstatus option')
        if subcommand == 'get_app_container' and len(rest) == 3 and rest[2] not in ('app', 'data', 'groups'):
            raise Rejected('unsupported app container type')
        return args
    if subcommand in ('install', 'addmedia') and len(rest) >= 2:
        plain_value(rest[0])
        if subcommand == 'install' and len(rest) != 2:
            raise Rejected('invalid install argument count')
        return [subcommand, rest[0], *(mounts.translate(value, cwd) for value in rest[1:])]
    if subcommand == 'io' and len(rest) == 3 and rest[1] == 'screenshot':
        plain_value(rest[0])
        return ['io', rest[0], 'screenshot', mounts.translate(rest[2], cwd)]
    raise Rejected('unsupported simctl subcommand')


class Bridge(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address, session, mounts, tools, timeout, output_limit):
        super().__init__(address, Handler)
        self.session = session
        self.mounts = mounts
        self.tools = tools
        self.token = secrets.token_hex(32)
        self.instance = secrets.token_hex(16)
        self.command_timeout = timeout
        self.output_limit = output_limit
        self.execution_lock = threading.Lock()
        self.child_lock = threading.Lock()
        self.child = None
        self.connections = threading.BoundedSemaphore(16)
        self.stopping = threading.Event()

    def process_request(self, request, address):
        if not self.connections.acquire(blocking=False):
            request.close()
            return
        request.settimeout(5)
        try:
            super().process_request(request, address)
        except BaseException:
            self.connections.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.connections.release()

    def terminate_child(self):
        with self.child_lock:
            child = self.child
            if child is not None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def stop(self):
        self.stopping.set()
        self.terminate_child()
        self.shutdown()

    def execute(self, argv, cwd):
        if not self.execution_lock.acquire(blocking=False):
            raise Rejected('another Xcode command is running')
        child = None
        status_read = None
        status_write = None
        try:
            if self.stopping.is_set():
                raise Rejected('bridge is stopping')
            try:
                home = pwd.getpwuid(os.getuid()).pw_dir
            except KeyError:
                home = str(self.session)
            environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                           'HOME': home,
                           'LANG': 'en_US.UTF-8', 'TMPDIR': str(self.session)}
            status_read, status_write = os.pipe()
            with self.child_lock:
                child = subprocess.Popen([sys.executable, os.path.abspath(__file__), '--worker',
                                          str(status_write), *argv], cwd=cwd, env=environment, shell=False,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, start_new_session=True, pass_fds=(status_write,))
                self.child = child
            os.close(status_write)
            status_write = None
            streams = [bytearray(), bytearray(), bytearray()]
            deadline = time.monotonic() + self.command_timeout
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ, 0)
                selector.register(child.stderr, selectors.EVENT_READ, 1)
                selector.register(status_read, selectors.EVENT_READ, 2)
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Xcode command exceeded time limit')
                    if self.stopping.is_set():
                        raise Rejected('bridge is stopping')
                    for key, _ in selector.select(0.1):
                        fd = key.fileobj if isinstance(key.fileobj, int) else key.fileobj.fileno()
                        data = os.read(fd, 65536)
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        streams[key.data].extend(data)
                        if len(streams[0]) + len(streams[1]) > self.output_limit or len(streams[2]) > 16:
                            raise Rejected('Xcode command exceeded output limit')
            status = int(streams[2].decode('ascii'))
            return {'version': 1, 'stdout': base64.b64encode(streams[0]).decode('ascii'),
                    'stderr': base64.b64encode(streams[1]).decode('ascii'),
                    'exit_code': min(255, status if status >= 0 else 128 - status)}
        finally:
            if child is not None:
                # Reap the leader only after killing its group, preventing PID reuse races.
                with self.child_lock:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.wait()
                    self.child = None
                child.stdout.close()
                child.stderr.close()
            if status_read is not None:
                os.close(status_read)
            if status_write is not None:
                os.close(status_write)
            self.execution_lock.release()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'CodexShellXcode/1'

    def log_message(self, *_):
        pass

    def reply(self, code, value):
        body = json.dumps(value, separators=(',', ':')).encode('utf-8')
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        self.close_connection = True

    def authenticated(self):
        values = self.headers.get_all('Authorization', [])
        if len(values) != 1 or not hmac.compare_digest(values[0].encode('utf-8'), ('Bearer ' + self.server.token).encode('ascii')):
            self.reply(401, {'error': 'authentication required'})
            return False
        return True

    def do_GET(self):
        if not self.authenticated():
            return
        if self.path != '/health':
            self.reply(404, {'error': 'unknown endpoint'})
            return
        self.reply(200, {'version': 1, 'instance': self.server.instance})

    def do_POST(self):
        if not self.authenticated():
            return
        if self.path not in ('/run', '/shutdown'):
            self.reply(404, {'error': 'unknown endpoint'})
            return
        try:
            lengths = self.headers.get_all('Content-Length', [])
            content_types = self.headers.get_all('Content-Type', [])
            if self.headers.get('Transfer-Encoding') or len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit():
                raise Rejected('invalid request length')
            length = int(lengths[0])
            if not 0 < length <= REQUEST_LIMIT:
                raise Rejected('request size limit exceeded')
            if len(content_types) != 1 or content_types[0].lower() not in ('application/json', 'application/json; charset=utf-8'):
                raise Rejected('unsupported content type')
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise Rejected('incomplete request')
            value = decode_json(raw)
            if self.path == '/shutdown':
                if value != {'version': 1, 'instance': self.server.instance} or type(value.get('version')) is not int:
                    raise Rejected('invalid instance identity')
                self.reply(200, {'version': 1, 'instance': self.server.instance})
                threading.Thread(target=self.server.stop, daemon=True).start()
                return
            if not isinstance(value, dict) or set(value) != {'version', 'command', 'args', 'cwd'} or type(value['version']) is not int or value['version'] != 1:
                raise Rejected('invalid request schema')
            argv, cwd = validate_command(value['command'], value['args'], value['cwd'], self.server.mounts, self.server.tools)
            self.reply(200, self.server.execute(argv, cwd))
        except (Rejected, OSError, subprocess.SubprocessError, TimeoutError, TypeError, ValueError, UnicodeError) as error:
            # Do not echo external argv, paths, tokens or subprocess output in diagnostics.
            self.reply(504 if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)) else 400,
                       {'error': 'command timeout' if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)) else 'request rejected'})


def private_directory(path):
    path = pathlib.Path(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Rejected('session directory must be owned and mode 0700')
    return path.resolve()


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        handle.write(data)


def read_private(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise Rejected('invalid private session file')
    return path.read_text(encoding='utf-8')


def control(options, session):
    if options.control == 'cleanup':
        shutil.rmtree(session)
        return 0
    manifest = decode_json(read_private(session / 'manifest.json').encode('utf-8'))
    token = read_private(session / 'token').strip()
    port = manifest['port']
    if type(port) is not int or not 1 <= port <= 65535 or manifest['version'] != 1:
        raise Rejected('invalid manifest')
    if options.control == 'matches':
        return 0 if manifest['mounts'] == [list(pair) for pair in MountMap(options.mount).pairs] else 1
    endpoint = '/shutdown' if options.control == 'stop' else '/health'
    data = json.dumps({'version': 1, 'instance': manifest['instance']}).encode('utf-8') if endpoint == '/shutdown' else None
    request = urllib.request.Request('http://127.0.0.1:' + str(port) + endpoint, data=data,
                                     headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=3) as response:
        value = decode_json(response.read(4096))
    if value != {'version': 1, 'instance': manifest['instance']}:
        raise Rejected('bridge identity mismatch')
    if options.control == 'health':
        print(port)
    return 0


def main():
    initial_parent = os.getppid()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', required=True)
    parser.add_argument('--mount', action='append', nargs=2, default=[])
    parser.add_argument('--bind', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--tool-root', default='/usr/bin', help='trusted executable directory; test harness only overrides this')
    parser.add_argument('--timeout', type=float, default=120, help='may only reduce the 120-second limit')
    parser.add_argument('--output-limit', type=int, default=OUTPUT_LIMIT, help='may only reduce the 8-MiB limit')
    parser.add_argument('--control', choices=('health', 'stop', 'matches', 'cleanup'))
    parser.add_argument('--project-root')
    parser.add_argument('--owner-pid', type=int, default=initial_parent)
    parser.add_argument('--validate-map', action='store_true')
    options = parser.parse_args()
    try:
        if options.validate_map:
            try:
                MountMap(options.mount)
                return 0
            except (Rejected, OSError):
                return 2
        session = private_directory(options.session)
        if options.control:
            return control(options, session)
        if options.owner_pid <= 0 or os.getppid() != options.owner_pid:
            raise Rejected('launcher no longer owns bridge process')
        if not 0 < options.timeout <= 120 or not 0 < options.output_limit <= OUTPUT_LIMIT or not 0 <= options.port <= 65535:
            raise Rejected('invalid execution bounds')
        mounts = MountMap(options.mount)
        if any(beneath(str(session), host) for host, _ in mounts.pairs) or (
                options.project_root and beneath(str(session), os.path.realpath(options.project_root))):
            raise Rejected('private session must be outside project and mounted roots')
        tool_root = pathlib.Path(options.tool_root).resolve()
        tools = {name: str(tool_root / name) for name in ('xcodebuild', 'xcrun')}
        if any(not os.path.isfile(path) or not os.access(path, os.X_OK) for path in tools.values()):
            raise Rejected('Xcode developer tools are unavailable')
        if os.getppid() != options.owner_pid:
            raise Rejected('launcher no longer owns bridge process')
        server = Bridge((options.bind, options.port), session, mounts, tools, options.timeout, options.output_limit)
        write_private(session / 'token', server.token + '\n')
        write_private(session / 'manifest.json', json.dumps({'version': 1, 'instance': server.instance,
                      'port': server.server_port, 'pid': os.getpid(), 'mounts': mounts.pairs}) + '\n')
        def monitor_parent():
            while not server.stopping.wait(0.5):
                if os.getppid() != options.owner_pid:
                    server.stop()
                    return
        threading.Thread(target=monitor_parent, daemon=True).start()
        def on_signal(_signum, _frame):
            threading.Thread(target=server.stop, daemon=True).start()
        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)
        try:
            if os.getppid() != options.owner_pid:
                raise Rejected('launcher no longer owns bridge process')
            server.serve_forever(poll_interval=0.1)
        finally:
            server.stopping.set()
            server.terminate_child()
            server.server_close()
        return 0
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
        print('Xcode: bridge operation failed; check prerequisites and private session data.', file=sys.stderr)
        return 1


def command_worker():
    # The supervisor remains group leader until its owner kills/reaps it. The actual
    # command status travels separately, so group cleanup never targets a reused PID.
    status_fd = int(sys.argv[2])
    try:
        try:
            child = subprocess.Popen(sys.argv[3:], shell=False, stdin=subprocess.DEVNULL, close_fds=True)
            status = child.wait()
        except OSError:
            status = 127
        os.write(status_fd, str(status).encode('ascii'))
    finally:
        os.close(status_fd)
        os.close(1)
        os.close(2)
    while True:
        signal.pause()


if __name__ == '__main__':
    if sys.argv[1:2] == ['--worker']:
        command_worker()
    else:
        sys.exit(main())
