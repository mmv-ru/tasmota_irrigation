#!/usr/bin/env python

import diff_match_patch
import logging
import requests
import time

logging.basicConfig(level=logging.ERROR, format="%(message)s")

tasmota_host = '172.17.252.43'
filename = 'watering.be'


class UploadVerificationError(RuntimeError):
    """Upload verification Failed!"""


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

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, exc_tb):
        self.session.close()

    def uploadfile(self, filename):
        """ Upload program file """
        print(f"Uploading '{filename}'")
        url_upload = 'http://{}/ufsu'.format(tasmota_host)
        with open(filename, 'rb') as f:
            files = {'file': f}
            response = self.session.post(url_upload, files=files)
            print(response.url, response.status_code)
            response.raise_for_status()

    def verifyfile(self, filename):
        """Download files"""
        print(f"Verification '{filename}'")
        ulr_download = f"http://{tasmota_host}/ufsd?download=/{filename}"
        response = self.session.get(ulr_download)
        print(response.url, response.status_code)
        response.raise_for_status()
        data_loaded = response.content
        with open(filename, 'rb') as f:
            data_file = f.read()
        if data_loaded == data_file:
            print("Uploadd verification Passed")
        else:
            print("Uploadd verification Failed")
            # print("file:\n", data_file.decode("utf-8"), sep=None)
            # print()
            # print("loaded:\n", data_loaded.decode("utf-8"), sep=None)
            # print()
            dmp = diff_match_patch.diff_match_patch()
            dmp.Diff_Timeout = 1  # or some other value, default is 1.0 seconds
            diffs = dmp.diff_main(data_loaded.decode("utf-8"),
                                  data_file.decode("utf-8"))
            dmp.diff_cleanupSemantic(diffs)
            patch = dmp.patch_make(diffs)
            textpatch = dmp.patch_toText(patch)
            # htmlSnippet = dmp.diff_prettyHtml(diffs)
            print("Unidiff:\n", textpatch, sep=None)
            print()
            raise UploadVerificationError("Upload verification Failed!")

    def berryCommand(self, command: str):
        """Berry command to load program"""
        print(f"Berry command '{command}'")
        url_berryconsole = f'http://{tasmota_host}/bc'
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
        url_console = f'http://{tasmota_host}/cs'
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
        url_console = 'http://{}/cs'.format(tasmota_host)
        payload = {'c2': '0', 'c1': command}
        response = self.session.get(url_console, params=payload)
        print(response.url, response.status_code)
        response.raise_for_status()
        # log = response.text
        # print("Berry Log:")
        # print(log)
        repr(response)


def main():
    with Tasmota(tasmota_host) as t:
        n_log1 = t.getLog()
        # TODO: Upload If files not match (to save controller flash)
        # TODO: Decompose verify to return boolean
        # TODO: May be make object for controller files?
        t.uploadfile(filename)
        time.sleep(10)
        t.verifyfile(filename)
        t.berryCommand(f'load("{filename}")')
        time.sleep(0.1)
        print("Show console log")
        begin_t = time.monotonic()
        n_log = n_log1
        while time.monotonic() < begin_t + 6:
            n_log = t.getLog(start_from=n_log['LastMsg'])
            # print((n_log['LastMsg'], n_log['B'], n_log['C'], n_log['D']))
            for line in filter(lambda x: len(x.strip()), n_log['lines']):
                print(line)
            time.sleep(0.2)
        # consoleCommand('BrRestart')


if __name__ == "__main__":
    main()
