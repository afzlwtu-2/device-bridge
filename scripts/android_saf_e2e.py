#!/usr/bin/env python3
"""App-scoped export test after android_ui_e2e.py. Creates one new shared folder.
No system settings, partitions, ADB, existing folders or projects are modified.
"""
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys
import xml.etree.ElementTree as ET
import android_ui_e2e as ui

run = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
folder = 'DeviceBridge-Test-' + run
temp = ui.PHONE_RUN + '/devicebridge-saf-test.xml'
guard = "focus=$(dumpsys window | sed -n '/mCurrentFocus=/p'); case \"$focus\" in *com.google.android.documentsui/*|*com.android.documentsui/*|*dev.devicebridge.devicebridge/*) ;; *) exit 41;; esac; "


def dump():
    ui.remote(guard+'timeout 12 uiautomator dump --compressed '+shlex.quote(temp)+' >/dev/null', True)
    return ET.fromstring(ui.remote('cat '+shlex.quote(temp), True))


def tap(label=None, kind=None):
    tree = dump()
    for n in tree.iter('node'):
        text = n.get('text') or n.get('content-desc')
        if text == label or (kind and n.get('class') == kind):
            bounds = list(map(int, re.findall(r'\d+', n.get('bounds', ''))))
            if len(bounds) != 4: continue
            a,b,c,d = bounds
            ui.remote(guard+f'input tap {(a+c)//2} {(b+d)//2}', True)
            return n
    raise RuntimeError('Missing picker control '+str(label or kind))


def main():
    evidence = {'run':run,'new_shared_folder':folder,'result':'INCOMPLETE'}
    try:
        tree = dump()
        if any('Save a copy' in (n.get('content-desc') or '') for n in tree.iter('node')):
            ui.tap(label='Save a copy…')
        tap(label='New folder')
        edit = tap(kind='android.widget.EditText')
        previous = edit.get('text') or ''
        command = guard+'input keyevent 123; '
        if previous: command += 'input keyevent '+' '.join(['67']*len(previous))+'; '
        command += shlex.join(['input','text',folder])
        ui.remote(command,True)
        tree = dump()
        labels = {n.get('text') or n.get('content-desc') for n in tree.iter('node')}
        button = next((v for v in ['OK','CREATE','Create'] if v in labels),None)
        if not button: raise RuntimeError('No create-folder confirmation')
        tap(label=button)
        tap(label='USE THIS FOLDER')
        tree = dump()
        labels = {n.get('text') or n.get('content-desc') for n in tree.iter('node')}
        if 'ALLOW' in labels: tap(label='ALLOW')
        elif 'Allow' in labels: tap(label='Allow')
        ui.wait_label('Verified download',timeout=30)
        # Only inspect the new test folder. Do not enumerate unrelated shared data.
        code = "from pathlib import Path; import json,hashlib; roots=[Path('/storage/emulated/0')/"+repr(folder)+",Path('/storage/emulated/0/Download')/"+repr(folder)+"]; p=next((r for r in roots if r.is_dir()),None); assert p is not None; print(json.dumps({str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in p.rglob('*') if f.is_file()}))"
        result = json.loads(ui.remote(shlex.join(['python','-c',code])))
        expected = hashlib.sha256(b'Actual standalone DeviceBridge GUI over LAN\n').hexdigest()
        if expected not in result.values(): raise RuntimeError('SAF copy did not match verified private download')
        evidence['copied_sha256'] = result
        evidence['result'] = 'PASS'
    except Exception as e:
        evidence['result']='FAIL';evidence['error']=str(e);raise
    finally:
        ui.remote('rm -f '+shlex.quote(temp),True)
        evidence['cleanup']='owned temporary UI XML removed; new test folder retained with verified copies; app remains open'
        (ui.ROOT/'docs/test-evidence'/('android-saf-'+run+'.json')).write_text(json.dumps(evidence,indent=2)+'\n')
        print(evidence['result'],flush=True)


if __name__=='__main__': main()
