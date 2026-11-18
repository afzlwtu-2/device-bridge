#!/usr/bin/env python3
"""Explicitly authorized physical DeviceBridge UI test; no ADB/system changes.

Uses temporary root only for focused app input, UI capture and normal-UID app
diagnostics. Start only with the user's APK/app-testing authorization. Firewall
approval is separate; this script never changes firewall rules.
"""
import datetime
import hashlib
import json
from pathlib import Path
import re
import select
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'dev.devicebridge.devicebridge'
SSH = ['ssh', '-p', '8022', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', 'afzl@10.100.102.33']
PHONE_RUN = '/data/data/com.termux/files/usr/tmp/devicebridge-build.IZZx3Jme/out'


def remote(command, privileged=False, timeout=20):
    if privileged:
        command = 'su -c ' + shlex.quote(command)
    p = subprocess.run(SSH + ['bash -c ' + shlex.quote(command)], capture_output=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(p.stderr.decode(errors='replace') + p.stdout.decode(errors='replace'))
    return p.stdout


def focus_guard():
    return "focus=$(dumpsys window | sed -n '/mCurrentFocus=/p'); case \"$focus\" in *dev.devicebridge.devicebridge/*) ;; *) exit 41;; esac; "


def dump():
    path = PHONE_RUN + '/devicebridge-test-ui.xml'
    remote(focus_guard() + 'timeout 12 uiautomator dump --compressed ' + shlex.quote(path) + ' >/dev/null', True)
    return ET.fromstring(remote('cat ' + shlex.quote(path), True))


def labels(tree):
    return [n.get('content-desc') or n.get('text') for n in tree.iter('node') if n.get('content-desc') or n.get('text')]


def tap(label=None, contains=None, kind=None):
    tree = dump()
    found = []
    for n in tree.iter('node'):
        value = n.get('content-desc') or n.get('text') or ''
        if ((label is not None and value == label) or (contains is not None and contains in value) or (kind is not None and n.get('class') == kind)):
            found.append(n)
    if not found:
        # Do not leak an invitation field in diagnostic output.
        raise RuntimeError('UI target not found: ' + str(label or contains or kind))
    node = found[0]
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
    remote(focus_guard() + f'input tap {(x1+x2)//2} {(y1+y2)//2}', True)


def wait_label(text, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        tree = dump()
        if any(text in v for v in labels(tree)):
            return tree
    raise RuntimeError('UI did not reach: ' + text)


def main():
    run = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    work = ROOT / '.work' / ('android-ui-' + run)
    work.mkdir(parents=True)
    fixture = work / 'fixture'
    (fixture / 'nested' / 'empty-dir').mkdir(parents=True)
    payload = b'Actual standalone DeviceBridge GUI over LAN\n'
    (fixture / 'gui-hello.txt').write_bytes(payload)
    (fixture / 'nested' / 'empty').write_bytes(b'')
    (fixture / 'nested' / 'gui-binary.bin').write_bytes(bytes(range(256)) * 32768)
    cli = ROOT / 'artifacts/linux/bridge-cli'
    state = work / 'state'
    common = [str(cli), '--state', str(state)]
    def local(*a):
        p = subprocess.run(common + list(a), capture_output=True, text=True, timeout=30)
        if p.returncode: raise RuntimeError(p.stderr)
        return json.loads(p.stdout)
    agent = None
    evidence = {'run': run, 'level': 'physical standalone Flutter Android GUI, real core and LAN', 'checks': [], 'result': 'INCOMPLETE'}
    stderr = (work / 'agent.stderr').open('w')
    try:
        laptop = local('init', 'Laptop GUI fixture')
        local('export', 'gui-fixture', str(fixture))
        agent = subprocess.Popen([str(ROOT/'artifacts/linux/bridge-agent'), '--state', str(state), '--interface', 'wlan0', '--lan-cidr', '10.100.102.69/24', '--port', '8731'], stdout=subprocess.PIPE, stderr=stderr, text=True)
        if not select.select([agent.stdout], [], [], 8)[0]: raise RuntimeError('agent not ready')
        evidence['agent'] = json.loads(agent.stdout.readline())
        invitation = local('invite')
        tree = dump()
        evidence['home_labels'] = labels(tree)
        print('Standalone home rendered; selecting approved LAN', flush=True)
        if any('Choose a local network' in v for v in labels(tree)):
            tap(label='Find devices')
            tap(contains='10.100.102.33/24')
            wait_label('Approved LAN')
        tap(label='Pair device')
        tap(kind='android.widget.EditText')
        encoded = json.dumps(invitation, separators=(',', ':'))
        # No shell concatenation of the invitation and no clipboard modification.
        remote(focus_guard() + shlex.join(['input', 'text', encoded]), True)
        tap(label='Review')
        wait_label('Verify this fingerprint')
        tap(label='Fingerprint matches')
        wait_label('outbound')
        pending = [p for p in local('peers') if p['status'] == 'pending']
        if len(pending) != 1: raise RuntimeError('expected one app pairing request')
        phone = pending[0]
        local('approve', phone['id'], 'gui-fixture', '1h', '10000000')
        tap(contains='Laptop GUI fixture')
        wait_label('1 paired devices')
        evidence['checks'].append('app paired via actual invitation/fingerprint/owner approval UI')
        tap(contains='Laptop GUI fixture')
        wait_label('Authenticated direct LAN')
        tap(contains='gui-fixture')
        wait_label('gui-hello.txt')
        evidence['checks'].append('device-detail browser listed granted laptop folder without peer IP entry')
        print('Pairing and browse passed; pulling entire folder', flush=True)
        tap(label='Pull this folder')
        tap(label='Pull')
        evidence['foreground_service_observation'] = remote('dumpsys activity services '+PACKAGE,True).decode(errors='replace')
        wait_label('Verified download', timeout=60)
        evidence['browser_labels'] = labels(dump())
        # run-as executes the verification as the app's ordinary UID, not root.
        appfile = '/data/user/0/' + PACKAGE + '/files/devicebridge/downloads/gui-fixture/gui-hello.txt'
        actual = remote(shlex.join(['run-as', PACKAGE, 'cat', appfile]), True)
        if actual != payload: raise RuntimeError('app-private received bytes differ')
        evidence['verified_sha256'] = hashlib.sha256(actual).hexdigest()
        evidence['app_uid'] = remote(shlex.join(['run-as', PACKAGE, 'id']), True).decode().strip()
        evidence['checks'].append('standalone app pulled verified nested folder; app-UID bytes match')
        png = remote(focus_guard() + 'screencap -p', True)
        (ROOT/'docs/test-evidence'/('android-gui-' + run + '.png')).write_bytes(png)
        evidence['result'] = 'PASS'
    except Exception as e:
        evidence['result'] = 'FAIL'
        evidence['error'] = str(e)
        raise
    finally:
        if agent is not None:
            agent.terminate()
            try: agent.wait(timeout=8)
            except subprocess.TimeoutExpired: agent.kill(); agent.wait(timeout=3)
        stderr.close()
        remote('rm -f ' + shlex.quote(PHONE_RUN + '/devicebridge-test-ui.xml'), True)
        evidence['cleanup'] = 'owned laptop listener stopped; owned UI temp XML removed; app left open'
        (ROOT/'docs/test-evidence'/('android-gui-' + run + '.json')).write_text(json.dumps(evidence, indent=2, ensure_ascii=False)+'\n')
        print(evidence['result'], flush=True)


if __name__ == '__main__': main()
