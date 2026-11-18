#!/usr/bin/env python3
"""Verify the optimized installed app against the already-authorized GUI fixture.
Requires the preceding android_ui_e2e pairing; never injects trust or permissions.
"""
import datetime
from checksums import xxh64_bytes
import json
from pathlib import Path
import re
import select
import subprocess
import android_ui_e2e as ui


def main():
    run=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    state=ui.ROOT/'.work/android-ui-20261118T063651Z/state'
    evidence={'run':run,'level':'physical optimized standalone Android APK','result':'INCOMPLETE'}
    log=(ui.ROOT/'.work'/'release-agent.stderr').open('w')
    agent=None
    try:
        agent=subprocess.Popen([str(ui.ROOT/'artifacts/linux/bridge-agent'),'--state',str(state),'--interface','wlan0','--lan-cidr','10.100.102.69/24','--port','8731'],stdout=subprocess.PIPE,stderr=log,text=True)
        if not select.select([agent.stdout],[],[],8)[0]:raise RuntimeError('agent readiness timeout')
        evidence['agent']=json.loads(agent.stdout.readline())
        ui.wait_label('Your devices.')
        ui.tap(contains='Laptop GUI fixture')
        ui.wait_label('Authenticated direct LAN')
        ui.tap(contains='gui-fixture')
        ui.wait_label('gui-hello.txt')
        tree=ui.dump();row=next(n for n in tree.iter('node') if 'gui-hello.txt' in (n.get('content-desc') or n.get('text') or ''))
        bounds=list(map(int,re.findall(r'\d+',row.get('bounds',''))))
        target=None
        for n in tree.iter('node'):
            if (n.get('content-desc') or n.get('text'))!='Pull':continue
            b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
            if len(b)==4 and b[1]>=bounds[1] and b[3]<=bounds[3]:target=b;break
        if target is None:raise RuntimeError('file pull control missing')
        a,b,c,d=target;ui.remote(ui.focus_guard()+f'input tap {(a+c)//2} {(b+d)//2}',True)
        ui.tap(label='Pull');ui.wait_label('Verified download')
        data=ui.remote('cat /data/user/0/dev.devicebridge.devicebridge/files/devicebridge/downloads/gui-hello.txt',True)
        expected=b'Actual standalone DeviceBridge GUI over LAN\n'
        if data!=expected:raise RuntimeError('release download bytes differ')
        evidence['xxh64']=xxh64_bytes(data);evidence['labels']=ui.labels(ui.dump())
        (ui.ROOT/'docs/test-evidence'/('android-release-'+run+'.png')).write_bytes(ui.remote(ui.focus_guard()+'screencap -p',True))
        evidence['result']='PASS'
    except Exception as e:evidence['result']='FAIL';evidence['error']=str(e);raise
    finally:
        if agent is not None:
            agent.terminate()
            try:agent.wait(timeout=8)
            except subprocess.TimeoutExpired:agent.kill();agent.wait(timeout=3)
        log.close()
        ui.remote('rm -f '+ui.PHONE_RUN+'/devicebridge-test-ui.xml',True)
        evidence['cleanup']='owned laptop agent stopped; owned UI XML removed; optimized app left open'
        (ui.ROOT/'docs/test-evidence'/('android-release-'+run+'.json')).write_text(json.dumps(evidence,indent=2)+'\n')
        print(evidence['result'],flush=True)


if __name__=='__main__':main()
