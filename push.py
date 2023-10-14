#!/usr/bin/env python

import requests

tasmota_host = '172.17.252.43'

# Upload program file
url_upload = 'http://{}/ufsu'.format(tasmota_host)
files = {'file': open('watering.be', 'rb')}
r_upload = requests.post(url_upload, files=files)
print(r_upload.url, r_upload.status_code)
r_upload.raise_for_status()
repr(r_upload.text)

# Berry command to load program
url_berryconsole = 'http://{}/bc'.format(tasmota_host)
payload = {'c2': '0', 'c1': 'load("watering.be")'}
r_cmdload = requests.get(url_berryconsole, params=payload)
print(r_cmdload.url, r_cmdload.status_code)
r_cmdload.raise_for_status()
repr(r_cmdload)

# Restart Berry VM
# url_console = 'http://{}/cs'.format(tasmota_host)
# payload = {'c2': '0', 'c1': 'BrRestart'}
# r_cmdload = requests.get(url_console, params=payload)
# print(r_cmdload.url, r_cmdload.status_code)
# r_cmdload.raise_for_status()
# repr(r_cmdload)
