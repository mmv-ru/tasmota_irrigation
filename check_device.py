#!/usr/bin/env python

"""Post-deploy smoke checks for the device — read-only.

Separate from deploy.py on purpose: deploy writes to the device (upload +
restart) and its rc=0 means "the device was updated and the script loaded",
while this script only reads state and its rc=0 means "the device is alive and
serving". Splitting keeps a flaky network check from poisoning the deploy exit
code, and lets the checks be re-run at any time — after a deploy, after a
manual `Restart 1`, or after touching anything on the device.

Usage:
  .pyvenv/bin/python check_device.py              # check current state
  .pyvenv/bin/python check_device.py --cold-restart
      send `Restart 1` first, wait the device back, then check — this is the
      path that exercises the cold boot (WiFi coming up after the deferred
      init), i.e. the /svc race the fix exists for.

Exit code: 0 = all checks passed, 1 = at least one problem (listed).
"""

import sys
import time

import requests

from deploy import (Tasmota, tasmota_host, WEB_TIMEOUT, INIT_MARKER,
                    analyze_log, ping_note)

# Status 10 = StatusSNS: the sensor JSON, which carries our json_append output
# (key "Watering") — an HTTP-only proof that the driver's telemetry is alive.
TELEMETRY_CMND = 'Status 10'
SVC_PAGE_MARKER = 'Сервисный режим'

# Cold-restart timing (measured on the device: webserver comes back in 10-20 s,
# but the command itself takes a moment to start rebooting).
RESTART_DOWN_TIMEOUT = 20.0  # seconds to watch the device go dark after Restart 1
WEB_UP_TIMEOUT = 25.0        # seconds to wait for the main page to answer 200 again


def _get(t, url, problems, ping_info, params=None, what=''):
    """GET with the shared timeout, turning a network error into a ping note.

    Tasmota serves `text/html` with no charset, so requests defaults to
    ISO-8859-1 and every Cyrillic marker would come back as mojibake — force
    UTF-8 (the charset the pages are actually written in) before matching."""
    try:
        r = t.session.get(url, params=params, timeout=WEB_TIMEOUT)
    except requests.exceptions.RequestException as e:
        print(f"{what} fetch failed (network): {e}")
        ping_note(t.tasmota_host, problems, ping_info)
        # The generic ping note does not say which endpoint failed, and that
        # matters: a Timeout on /svc is the dead-callback hang, not a dead box.
        problems.append(f"{what}: запрос не выполнен ({type(e).__name__})")
        return None
    r.encoding = 'utf-8'
    return r


def check_main(t, problems, ping_info):
    """Main page: 200 + channel sections. Same check deploy.py does."""
    t.check_web(problems, ping_info)


def check_channels(t, problems, ping_info):
    """Channel rows come from the XHR the main page calls (/?m=1), not from the
    static '/' — there `tr.sec` is only the CSS injected by
    web_add_main_button(), so it proves injection, not rendering (see tests.md,
    known limitation 3). 'Канал 1' proves the driver really rendered the rows."""
    r = _get(t, f'http://{t.tasmota_host}/', problems, ping_info,
             params={'m': '1'}, what='main XHR /?m=1')
    if r is None:
        return
    if r.status_code != 200:
        problems.append(f"/?m=1 вернул HTTP {r.status_code}")
        return
    if 'Канал 1' not in r.text:
        problems.append("/?m=1 200, но секции каналов ('Канал 1') не отрисованы")
        return
    print("channels OK: /?m=1 renders 'Канал 1'")


def check_svc(t, problems, ping_info):
    """/svc must answer 200 with the service page.

    The interesting failure mode is a *hang* (0 bytes until timeout): after a
    BrRestart the C-side route can still be registered while its Berry callback
    belongs to a dead VM, so the request never gets answered. requests raises
    Timeout, which lands in the network branch below."""
    r = _get(t, f'http://{t.tasmota_host}/svc', problems, ping_info, what='/svc')
    if r is None:
        return
    if r.status_code != 200:
        problems.append(f"/svc вернул HTTP {r.status_code}")
        return
    if SVC_PAGE_MARKER not in r.text:
        problems.append(f"/svc 200, но '{SVC_PAGE_MARKER}' не найден в ответе")
        return
    print(f"/svc OK: 200, {len(r.text)} bytes")


def check_telemetry(t, problems, ping_info):
    """StatusSNS must contain the 'Watering' block appended by json_append()."""
    r = _get(t, f'http://{t.tasmota_host}/cm', problems, ping_info,
             params={'cmnd': TELEMETRY_CMND}, what='Status 10')
    if r is None:
        return
    if r.status_code != 200:
        problems.append(f"телеметрия вернула HTTP {r.status_code} ({TELEMETRY_CMND})")
        return
    if '"Watering"' not in r.text:
        problems.append(f"телеметрия: блок 'Watering' отсутствует в {TELEMETRY_CMND}")
        return
    print("telemetry OK: 'Watering' present in StatusSNS")


def read_log(t, problems, ping_info):
    """All non-empty console log lines currently in the device's ring buffer."""
    try:
        n_log = t.getLog()
    except requests.exceptions.RequestException as e:
        print(f"Log fetch failed (network): {e}")
        ping_note(t.tasmota_host, problems, ping_info)
        return None
    return [l for l in n_log['lines'] if l.strip()]


def check_log(t, problems, ping_info, wait_for_marker):
    """Turn crashes / a missing init marker into problems.

    wait_for_marker=True (cold restart) polls up to the deploy timeout: a fresh
    boot needs a few seconds to reach the marker, and there it is a hard
    requirement. The normal path reads the ring buffer once — on a long-running
    device the boot lines have scrolled out, so the marker's absence is only a
    note (the HTTP checks are what proves the driver is alive), while crash
    patterns still in the window are real and fail the run."""
    if wait_for_marker:
        lines = t.collect_log(problems, ping_info)
        crashes, init_ok = analyze_log(lines)
        if not init_ok:
            if not lines:
                # collect_log reported nothing of its own (network error path
                # is already covered by ping_note) — say it plainly anyway.
                problems.append(f"лог после Restart 1 не прочитан — маркер "
                                f"'{INIT_MARKER}' не найден")
            # non-empty: collect_log already appended the marker timeout
            return
    else:
        lines = read_log(t, problems, ping_info)
        if lines is None:
            return
        crashes, init_ok = analyze_log(lines)
        if not init_ok:
            print(f"note: '{INIT_MARKER}' вытеснен из окна лога "
                  "(кольцевой буфер короче аптайма) — жёсткая проверка маркера "
                  "есть в --cold-restart")
    for line in crashes:
        print("  " + line)
    if crashes:
        problems.append("ошибка в логах:")
    print(f"log: {len(lines)} строк в окне, {len(crashes)} crash")


def wait_down(t, timeout):
    """Wait until the device stops answering — the *start* of the reboot.

    `Restart 1` does not reboot instantly: Tasmota finishes the command first
    (saves settings, closes sessions), so the web server keeps serving for a
    moment. `wait_device_up()` polls every 2 s and happily returns True inside
    that pre-restart window; the checks that follow then run against a device
    that is actually rebooting and every one of them fails with connection
    refused (observed in the field). So: wait for the device to go dark first,
    and only then wait for it back."""
    begin = time.monotonic()
    while time.monotonic() - begin < timeout:
        try:
            t.session.get(f'http://{t.tasmota_host}/cs', timeout=(2, 3))
            time.sleep(1)
        except requests.exceptions.RequestException:
            print("device went down (reboot started)")
            return True
    print(f"note: устройство не уходило в офлайн за {int(timeout)} с — продолжаем")
    return False


def wait_web_up(t, timeout):
    """Wait until the main page answers 200.

    `wait_device_up()` only proves `/cs` (the console endpoint) is reachable;
    the HTTP checks need the page itself, and Berry may still be loading its
    modules at that point. Polling the actual URL makes the run deterministic."""
    begin = time.monotonic()
    while time.monotonic() - begin < timeout:
        try:
            r = t.session.get(f'http://{t.tasmota_host}/', timeout=(3, 5))
            if r.status_code == 200:
                return True
        except requests.exceptions.RequestException:
            pass
        time.sleep(2)
    return False


def cold_restart(t, problems, ping_info):
    """Send `Restart 1`, wait the device down and back, then the init marker."""
    print("Cold start: Restart 1")
    try:
        t.consoleCommand('Restart 1')
    except requests.exceptions.RequestException as e:
        print(f"Restart command failed (network): {e}")
        ping_note(t.tasmota_host, problems, ping_info)
        return False
    wait_down(t, timeout=RESTART_DOWN_TIMEOUT)
    if not t.wait_device_up():
        problems.append("устройство не вернулось после полного рестарта (Restart 1)")
        return False
    if not wait_web_up(t, timeout=WEB_UP_TIMEOUT):
        problems.append("главная страница не поднялась после Restart 1")
        return False
    return True


def main():
    args = sys.argv[1:]
    unknown = [a for a in args if a not in ('--cold-restart',)]
    if unknown:
        print(__doc__)
        sys.exit(2)
    cold = '--cold-restart' in args

    problems = []          # human-readable failures; non-empty -> exit 1
    ping_info = {'done': False, 'text': None}
    with Tasmota(tasmota_host) as t:
        if cold:
            if cold_restart(t, problems, ping_info):
                check_log(t, problems, ping_info, wait_for_marker=True)
        else:
            check_log(t, problems, ping_info, wait_for_marker=False)

        # HTTP checks run regardless of the log verdict — collect the whole
        # picture before deciding the exit code (same rule as deploy.py).
        time.sleep(1)
        check_main(t, problems, ping_info)
        check_channels(t, problems, ping_info)
        check_svc(t, problems, ping_info)
        check_telemetry(t, problems, ping_info)

    if problems:
        print("\n=== Check problems ===")
        for p in problems:
            print(" -", p)
        print("Checks FAILED")
        sys.exit(1)
    print("Checks OK: log clean, main page up, channels rendered, /svc alive, "
          "telemetry present")
    sys.exit(0)


if __name__ == "__main__":
    main()
