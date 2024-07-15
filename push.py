#!/usr/bin/env python

import requests
import time

tasmota_host = '172.17.252.43'
filename = 'watering.be'


class UploadVerificationError(RuntimeError):
    """Upload verification Failed!"""


def uploadfile():
    """ Upload program file """
    print("Uploading")
    url_upload = 'http://{}/ufsu'.format(tasmota_host)
    with open(filename, 'rb') as f:
        files = {'file': f}
        r_upload = requests.post(url_upload, files=files)
        print(r_upload.url, r_upload.status_code)
        r_upload.raise_for_status()
        repr(r_upload.text)
        print(r_upload.text)


def verifyfile():
    """Download files"""
    print("Verification")
    ulr_download = f"http://{tasmota_host}/ufsd?download=/{filename}"
    r_download = requests.get(ulr_download)
    print(r_download.url, r_download.status_code)
    r_download.raise_for_status()
    data_loaded = r_download.content
    with open(filename, 'rb') as f:
        data_file = f.read()
    if data_loaded == data_file:
        print("Uploadd verification Passed")
    else:
        raise UploadVerificationError("Upload verification Failed!")


def berryCommand(command: str):
    """Berry command to load program"""
    print("Script reload")
    url_berryconsole = f'http://{tasmota_host}/bc'
    payload = {'c2': '0', 'c1': command}
    r_cmdload = requests.get(url_berryconsole, params=payload)
    print(r_cmdload.url, r_cmdload.status_code)
    r_cmdload.raise_for_status()
    repr(r_cmdload)
    print(r_cmdload.text)


def getLog(start_from: int = None):
    """Show log"""
    if not start_from:
        start_from = 0
    print("Show console log")
    url_console = f'http://{tasmota_host}/cs'
    payload = {'c2': str(start_from)}
    r_cmdload = requests.get(url_console, params=payload)
    print(r_cmdload.url, r_cmdload.status_code)
    r_cmdload.raise_for_status()
    repr(r_cmdload)
    LastMsg, B, C = r_cmdload.text.split("}", 2)
    log = C[1:]
    C = C[0:1]
    return {'LastMsg': LastMsg, 'B': B, 'C': C, 'lines': log.split("/n")}


def consoleCommand(command: str):
    """Restart Berry VM"""
    print(f"Tasmota command ({command})")
    url_console = 'http://{}/cs'.format(tasmota_host)
    payload = {'c2': '0', 'c1': command}
    r_cmdload = requests.get(url_console, params=payload)
    print(r_cmdload.url, r_cmdload.status_code)
    r_cmdload.raise_for_status()
    repr(r_cmdload)


def main():
    o_log1 = getLog()
    uploadfile()
    verifyfile()
    berryCommand(f'load("{filename}")')
    time.sleep(6)
    o_log = getLog(start_from=o_log1['LastMsg'])
    print((o_log['LastMsg'], o_log['B'], o_log['C']))
    for line in o_log['lines']:
        print(line)
    # consoleCommand('BrRestart')


if __name__ == "__main__":
    main()
