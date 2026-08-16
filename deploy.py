#!/usr/bin/env python

import diff_match_patch
import logging
import platform
import re
import requests
import socket
import subprocess
import sys
import time

logging.basicConfig(level=logging.ERROR, format="%(message)s")

tasmota_host = '172.17.252.43'
filename = 'watering.be'

# Berry crash / init-failure patterns looked up in the console log after BrRestart.
# "Watering driver initialized" (watering.be) is the marker that the script loaded
# and its boot section finished without an exception.
INIT_MARKER = 'Watering driver initialized'
LOG_TIMEOUT = 30.0      # seconds to wait for INIT_MARKER after restart
LOG_OBSERVE = 5.0       # extra seconds of log monitoring after the marker appears
LOG_POLL = 0.2          # log poll interval
WEB_TIMEOUT = 10.0
# Heap fragmentation (from /in "Free Memory ... (frag. N%)") above which a full
# device restart (Restart 1) is done instead of a Berry-only BrRestart. High
# fragmentation was observed to break both the /ufsu upload and the script load
# (MEMORY ALLOCATION FAILED) after BrRestart; only a full restart resets it.
FRAG_THRESHOLD = 40.0
FULL_RESTART_WAIT = 40.0  # seconds to poll the device back after Restart 1
FULL_RESTART_POLL = 2.0
CRASH_PATTERNS = [
    'type_error', 'syntax_error', 'index_error',
    'stack traceback', 'undeclared',
    'Giving up on delayed sensor init',
    'WARNING: Watering driver NOT registered',
    'MEMORY ALLOCATION FAILED',
]


def ping_host(host, timeout=2):
    """ICMP ping via the system 'ping'; fallback to a TCP connect to :80.

    Returns (ok: bool, detail: str)."""
    try:
        if platform.system() == "Windows":
            cmd = ["ping", "-n", "1", "-w", str(timeout * 1000), host]
        else:
            cmd = ["ping", "-c", "1", "-W", str(timeout), host]
        res = subprocess.run(cmd, capture_output=True, timeout=timeout + 2)
        if res.returncode == 0:
            return True, "ping ok"
        return False, "ping exit %d" % res.returncode
    except FileNotFoundError:
        try:
            with socket.create_connection((host, 80), timeout=timeout):
                return True, "TCP :80 ok (no system ping)"
        except OSError as e:
            return False, "TCP :80 check failed: %s" % e
    except Exception as e:
        return False, "ping error: %s" % e


def ping_note(host, problems, ping_info):
    """On the first network failure run a ping check and report it once;
    later network failures in the same run stay silent (already covered)."""
    if ping_info['done']:
        return
    ping_info['done'] = True
    ok, detail = ping_host(host)
    if ok:
        text = "устройство отвечает на пинг, но сетевой запрос не прошёл"
    else:
        text = "тест пинг на устройство не проходит (%s)" % detail
    problems.append(text)


def analyze_log(lines):
    """Return (crash_lines, init_ok) from collected berry console log."""
    crashes = [l for l in lines if any(p in l for p in CRASH_PATTERNS)]
    init_ok = any(INIT_MARKER in l for l in lines)
    return crashes, init_ok

# How to activate the uploaded script on the device:
#   HOT_RELOAD = False -> BrRestart: clean reboot, autoexec.be loads the script
#                         on boot. Reliable on real hardware (no stale driver
#                         instance from the previous session crashing the load).
#   HOT_RELOAD = True  -> load("<filename>"): hot reload in the running VM.
#                         Only safe when no previous driver instance is still
#                         registered; otherwise its callbacks fire during the
#                         new init and crash it.
HOT_RELOAD = False


class UploadVerificationError(RuntimeError):
    """Upload verification Failed!"""


DEFAULT_TIMEOUT = (5, 15)  # connect / read seconds


def _timeout_wrapped(request_fn):
    """Wrap Session.request to apply a default (connect, read) timeout when the
    caller did not pass an explicit one."""
    def wrapped(method, url, **kwargs):
        if 'timeout' not in kwargs or kwargs['timeout'] is None:
            kwargs['timeout'] = DEFAULT_TIMEOUT
        return request_fn(method, url, **kwargs)
    return wrapped


class Tasmota:
    """Network Interaction with Tasmota IoT device"""

    def __init__(self, address):
        self.tasmota_host = address
        self.session = requests.Session()
        self.session.mount("http://",
                           requests.adapters.HTTPAdapter(pool_connections=10,
                                                         pool_maxsize=1,
                                                         max_retries=3,
                                                         pool_block=True))
        # No request should block forever on a dead/unreachable device: every
        # request (upload, download, console, web) inherits this timeout and
        # raises requests.exceptions so main() can fall back to a ping check.
        self.session.request = _timeout_wrapped(self.session.request)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, exc_tb):
        self.session.close()

    def uploadfile(self, filename):
        """ Upload program file """
        print(f"Uploading '{filename}'")
        # Tasmota keeps Web.upload_file_type (default UPL_TASMOTA) in a global.
        # Only a file-manager page render (GET /ufsd) sets it to UPL_UFSFILE;
        # the file-download branch (GET /ufsd?download=) returns early and does
        # NOT. A direct POST /ufsu while the global is still UPL_TASMOTA is
        # rejected as "Invalid file signature" (magic byte 0xE9 check) and the
        # file is left untouched. Render the file manager page first so the
        # upload is always accepted.
        init = self.session.get(f'http://{self.tasmota_host}/ufsd')
        init.raise_for_status()
        with open(filename, 'rb') as f:
            size = len(f.read())
        url_upload = 'http://{}/ufsu?fsz={}'.format(self.tasmota_host, size)
        with open(filename, 'rb') as f:
            files = {'file': f}
            response = self.session.post(url_upload, files=files)
            print(response.url, response.status_code)
            response.raise_for_status()

    def download(self, filename):
        """Download file content from device filesystem"""
        print(f"Downloading '{filename}'")
        url_download = f"http://{self.tasmota_host}/ufsd?download=/{filename}"
        response = self.session.get(url_download)
        print(response.url, response.status_code)
        response.raise_for_status()
        return response.content

    def files_equal(self, filename) -> bool:
        """True if device copy matches local file"""
        with open(filename, 'rb') as f:
            data_file = f.read()
        return self.download(filename) == data_file

    def print_unidiff(self, filename):
        """Print unidiff between local file and device copy"""
        with open(filename, 'rb') as f:
            data_file = f.read()
        data_loaded = self.download(filename)
        dmp = diff_match_patch.diff_match_patch()
        dmp.Diff_Timeout = 1
        diffs = dmp.diff_main(data_loaded.decode("utf-8"),
                              data_file.decode("utf-8"))
        dmp.diff_cleanupSemantic(diffs)
        print("Unidiff:\n", dmp.patch_toText(dmp.patch_make(diffs)), sep=None)
        print()

    def verifyfile(self, filename) -> bool:
        """Verify uploaded file, print unidiff on mismatch"""
        print(f"Verification '{filename}'")
        if self.files_equal(filename):
            print("Upload verification Passed")
            return True
        print("Upload verification Failed")
        self.print_unidiff(filename)
        return False

    def upload_if_changed(self, filename) -> bool:
        """Upload file only if device copy differs; True if uploaded"""
        if self.files_equal(filename):
            print(f"'{filename}' up to date")
            return False
        self.uploadfile(filename)
        return True

    def pushfile(self, filename, attempts: int = 3) -> bool:
        """Upload if changed, verify, retrying up to 'attempts' times"""
        if self.files_equal(filename):
            print(f"'{filename}' up to date")
            return True
        for attempt in range(1, attempts + 1):
            if attempt > 1:
                print(f"Upload retry {attempt}/{attempts}")
            self.uploadfile(filename)
            time.sleep(10)
            if self.verifyfile(filename):
                return True
        return False

    def berryCommand(self, command: str):
        """Berry command to load program"""
        print(f"Berry command '{command}'")
        url_berryconsole = f'http://{self.tasmota_host}/bc'
        payload = {'c2': '0', 'c1': command}
        response = self.session.get(url_berryconsole, params=payload)
        print(response.url, response.status_code)
        response.raise_for_status()
        repr(response)
        print(response.text)

    def getLog(self, start_from: int = None):
        """Show log"""
        if not start_from:
            start_from = 0
        url_console = f'http://{self.tasmota_host}/cs'
        payload = {'c2': str(start_from)}
        response = self.session.get(url_console, params=payload)
        # print(response.url, response.status_code)
        response.raise_for_status()
        # repr(response)
        LastMsg, B, C = response.text.split("}", 2)
        log = C[1:-2]
        D = C[-1:]
        C = C[0:1]
        return {'LastMsg': LastMsg, 'B': B, 'C': C, 'D': D,
                'lines': log.split("/n")}

    def consoleCommand(self, command: str):
        """Tasmota command"""
        print(f"Tasmota command ({command})")
        url_console = 'http://{}/cs'.format(self.tasmota_host)
        payload = {'c2': '0', 'c1': command}
        response = self.session.get(url_console, params=payload)
        print(response.url, response.status_code)
        response.raise_for_status()
        # log = response.text
        # print("Berry Log:")
        # print(log)
        repr(response)

    def get_fragmentation(self):
        """Read /in and parse heap free KB and fragmentation percent.

        Returns (free_kb: float, frag: float) or None if the page did not
        parse (e.g. the Info page changed). Uses a short explicit timeout so
        a dead device raises quickly instead of blocking the run."""
        try:
            r = self.session.get(f'http://{self.tasmota_host}/in', timeout=WEB_TIMEOUT)
            if r.status_code != 200:
                return None
        except requests.exceptions.RequestException:
            return None
        m = re.search(
            r'Free Memory}\s*([\d.]+)\s*KB\s*\(frag\.\s*([\d.]+)%\)', r.text)
        if not m:
            return None
        return float(m.group(1)), float(m.group(2))

    def wait_device_up(self):
        """Poll the device back after a full 'Restart 1'.

        A full restart takes the webserver down for ~10-20 s; any network
        error in this window is expected, so nothing is reported as a
        problem here. Returns True once a request succeeds."""
        begin = time.monotonic()
        while time.monotonic() - begin < FULL_RESTART_WAIT:
            try:
                self.session.get(f'http://{self.tasmota_host}/cs',
                                 timeout=WEB_TIMEOUT)
                return True
            except requests.exceptions.RequestException:
                time.sleep(FULL_RESTART_POLL)
        return False

    def collect_log(self, problems, ping_info):
        """Poll the console log after restart until INIT_MARKER + a short
        observation window. Returns the collected (non-empty) lines.

        A requests failure raises a RequestException; the caller (main) turns
        it into a ping check via ping_note()."""
        try:
            n_log = self.getLog()
        except requests.exceptions.RequestException as e:
            print(f"Log fetch failed (network): {e}")
            ping_note(self.tasmota_host, problems, ping_info)
            return []
        lines = []
        seen_marker = False

        def _consume(n_log):
            nonlocal seen_marker
            for line in filter(lambda x: len(x.strip()), n_log['lines']):
                lines.append(line)
                if INIT_MARKER in line:
                    seen_marker = True

        # The first call returns the whole log; the marker may already be in
        # it right after a quick BrRestart, so it must be consumed too.
        _consume(n_log)
        begin = time.monotonic()
        while time.monotonic() - begin < LOG_TIMEOUT:
            if seen_marker:
                break
            try:
                n_log = self.getLog(start_from=n_log['LastMsg'])
            except requests.exceptions.RequestException as e:
                print(f"Log fetch failed (network): {e}")
                ping_note(self.tasmota_host, problems, ping_info)
                return lines
            _consume(n_log)
            time.sleep(LOG_POLL)
        if not seen_marker:
            problems.append(
                f"таймаут получения логов (нет '{INIT_MARKER}' за {int(LOG_TIMEOUT)} с)")
            return lines
        # A few more seconds after init so late startup errors are caught too.
        t_end = time.monotonic() + LOG_OBSERVE
        while time.monotonic() < t_end:
            try:
                n_log = self.getLog(start_from=n_log['LastMsg'])
            except requests.exceptions.RequestException as e:
                print(f"Log fetch failed (network): {e}")
                ping_note(self.tasmota_host, problems, ping_info)
                return lines
            _consume(n_log)
            time.sleep(LOG_POLL)
        return lines

    def check_web(self, problems, ping_info):
        """Main page must return 200 and contain channel sections (tr.sec)."""
        try:
            response = self.session.get(
                f'http://{self.tasmota_host}/', timeout=WEB_TIMEOUT)
            if response.status_code != 200:
                problems.append(f"главная страница вернула HTTP {response.status_code}")
                return
            if 'tr.sec' not in response.text:
                problems.append("главная страница 200, но каналы (tr.sec) не найдены")
        except requests.exceptions.RequestException as e:
            print(f"Main page fetch failed (network): {e}")
            ping_note(self.tasmota_host, problems, ping_info)


def _restart_and_collect(t, full):
    """Restart the device (full=Restart 1 else BrRestart), wait it back if
    full, then collect the console log until the init marker appears.

    Returns (lines, init_ok, crashes, problems) where problems is a fresh
    list scoped to this attempt — a retry replaces the previous one."""
    attempt_problems = []
    ping_info = {'done': False, 'text': None}
    try:
        if full:
            t.consoleCommand('Restart 1')
        elif HOT_RELOAD:
            t.berryCommand(f'load("{filename}")')
        else:
            t.consoleCommand('BrRestart')
    except requests.exceptions.RequestException as e:
        print(f"Restart command failed (network): {e}")
        ping_note(t.tasmota_host, attempt_problems, ping_info)
        return [], False, [], attempt_problems
    if full and not t.wait_device_up():
        attempt_problems.append(
            "устройство не вернулось после полного рестарта (Restart 1)")
        return [], False, [], attempt_problems
    if full:
        time.sleep(2)
    lines = t.collect_log(attempt_problems, ping_info)
    crashes, init_ok = analyze_log(lines)
    return lines, init_ok, crashes, attempt_problems


def main():
    problems = []          # human-readable failures; non-empty -> exit 1
    ping_info = {'done': False, 'text': None}
    with Tasmota(tasmota_host) as t:
        # 0. Check heap fragmentation before uploading. A fragmented/exhausted
        #    heap was observed to break both /ufsu uploads and the script load
        #    after BrRestart (MEMORY ALLOCATION FAILED); only a full device
        #    restart resets it. Do it up front so the whole run is clean.
        mem = t.get_fragmentation()
        if mem:
            print(f"Memory: free {mem[0]:.0f} KB, frag {mem[1]:.0f}%")
        if mem and mem[1] >= FRAG_THRESHOLD:
            print(f"Heap frag {mem[1]:.0f}% >= {FRAG_THRESHOLD:.0f}%: "
                  "полный рестарт перед аплоадом")
            try:
                t.consoleCommand('Restart 1')
            except requests.exceptions.RequestException as e:
                print(f"Restart command failed (network): {e}")
                ping_note(tasmota_host, problems, ping_info)
            else:
                if not t.wait_device_up():
                    problems.append(
                        "устройство не вернулось после полного рестарта (Restart 1)")
                time.sleep(2)

        # 1. Upload (if changed) + verify. Continue on failure so the log and
        #    web checks still run and report their own state.
        try:
            if not t.pushfile(filename):
                problems.append("upload verification failed")
        except requests.exceptions.RequestException as e:
            print(f"Upload failed (network): {e}")
            ping_note(tasmota_host, problems, ping_info)

        # 2-3. Restart the Berry VM and watch the console log. Try BrRestart
        #    first; if the fresh load died with MEMORY ALLOCATION FAILED, retry
        #    once with a full device restart (it clears the heap and the log).
        lines, init_ok, crashes, attempt_problems = _restart_and_collect(t, False)
        if any('MEMORY ALLOCATION FAILED' in l for l in lines):
            print("MEMORY ALLOCATION FAILED после BrRestart: "
                  "повтор с полным рестартом")
            lines, init_ok, crashes, attempt_problems = \
                _restart_and_collect(t, True)
        if init_ok:
            print("Init marker found: Watering driver initialized")
        problems.extend(attempt_problems)
        if crashes:
            problems.append("ошибка в логах после старта:")
            for line in crashes:
                print("  " + line)

        # 4. Main page must answer 200 and render channel sections. Runs
        #    regardless of log problems — collect the full picture first.
        time.sleep(1)
        t.check_web(problems, ping_info)

    # 5. Aggregate: all checks already ran; only now decide the exit code.
    if problems:
        print("\n=== Deploy problems ===")
        for p in problems:
            print(" -", p)
        print("Deploy FAILED")
        sys.exit(1)
    print("Deploy OK: upload verified, no startup errors, main page up")
    sys.exit(0)


if __name__ == "__main__":
    main()
