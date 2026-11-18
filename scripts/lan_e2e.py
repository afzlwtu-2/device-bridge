#!/usr/bin/env python3
"""Actual laptop <-> physical Termux test, using only disposable owned fixtures.

Does not install APKs, invoke root, change networks/firewalls, or launch persistence.
Discovery, not an entered peer IP, selects the application endpoint.
"""
import argparse
import datetime
from checksums import xxh64
import json
from pathlib import Path
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phone', default='afzl@10.100.102.33')
    parser.add_argument('--phone-port', default='8022')
    parser.add_argument('--phone-snapshot', required=True)
    parser.add_argument('--laptop-cidr', default='10.100.102.69/24')
    parser.add_argument('--phone-cidr', default='10.100.102.33/24')
    parser.add_argument('--interface', default='wlan0')
    parser.add_argument('--agent-port', default='8731')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    run = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    work = root / '.work' / ('lan-' + run)
    work.mkdir(parents=True)
    fixture = work / 'approved-fixture'
    (fixture / 'nested' / 'empty directory').mkdir(parents=True)
    (fixture / 'hello 空格.txt').write_bytes(b'DeviceBridge physical LAN test\n')
    (fixture / 'empty').write_bytes(b'')
    (fixture / 'nested' / 'binary.bin').write_bytes(bytes(range(256)) * 16384)
    state = work / 'laptop-state'
    cli = root / 'artifacts/linux/bridge-cli'
    common = [str(cli), '--state', str(state), '--interface', args.interface, '--lan-cidr', args.laptop_cidr]
    remote_work = args.phone_snapshot + '/e2e-' + run
    remote_cli = [args.phone_snapshot + '/out/bridge-cli', '--state', remote_work + '/state', '--interface', args.interface, '--lan-cidr', args.phone_cidr]
    ssh = ['ssh', '-p', args.phone_port, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', args.phone]
    evidence = {'run': run, 'phone_snapshot': args.phone_snapshot, 'laptop_cidr': args.laptop_cidr,
                'phone_cidr': args.phone_cidr, 'checks': [], 'cleanup': 'pending', 'acceptance': 'physical Termux CLI, not Flutter GUI'}

    def local(*a):
        p = subprocess.run(common + list(a), capture_output=True, text=True, timeout=180)
        if p.returncode: raise RuntimeError(p.stderr)
        return json.loads(p.stdout)

    def remote(command, data=None):
        p = subprocess.run(ssh + ['bash -c ' + shlex.quote(shlex.join(command))], input=data,
                           capture_output=True, text=True, timeout=180)
        if p.returncode: raise RuntimeError(p.stderr)
        return p.stdout

    def phone(*a, data=None):
        return json.loads(remote(remote_cli + list(a), data))

    agent = None
    log = (work / 'agent.stderr').open('w')
    try:
        laptop = local('init', 'DeviceBridge laptop fixture')
        local('export', 'fixture', str(fixture))
        agent = subprocess.Popen([str(root / 'artifacts/linux/bridge-agent'), '--state', str(state),
                                  '--interface', args.interface, '--lan-cidr', args.laptop_cidr, '--port', args.agent_port],
                                 stdout=subprocess.PIPE, stderr=log, text=True)
        # Bounded readiness, not a startup sleep.
        import select
        if not select.select([agent.stdout], [], [], 10)[0]: raise RuntimeError('agent did not become ready')
        evidence['agent'] = json.loads(agent.stdout.readline())
        mobile = phone('init', 'DeviceBridge phone fixture')
        invitation = local('invite')
        discovered = phone('discover')
        evidence['discovery'] = discovered
        if not any(v['device_id'] == laptop['id'] for v in discovered):
            raise RuntimeError('laptop mDNS not discovered on physical phone; no IP fallback used')
        evidence['checks'].append('phone discovered laptop by DNS-SD without peer IP entry')
        phone('pair', '-', data=json.dumps(invitation))
        local('approve', mobile['id'], 'fixture', '1h', '100000000')
        phone('finish', laptop['id'])
        evidence['checks'].append('mutual pairing with explicit fixture root grant')
        evidence['route'] = phone('resolve', laptop['id'])
        evidence['roots'] = phone('roots', laptop['id'])
        evidence['listing'] = phone('list', laptop['id'], 'fixture', '.')
        for label, relative in [('single', 'hello 空格.txt'), ('folder', '.')]:
            start = time.monotonic()
            receipt = phone('pull', laptop['id'], 'fixture', relative, remote_work + '/' + label)
            evidence[label] = {'receipt': receipt, 'elapsed_including_ssh_and_discovery_seconds': round(time.monotonic()-start, 6)}
        expected = {p.relative_to(fixture).as_posix(): xxh64(p) for p in fixture.rglob('*') if p.is_file()}
        code = "import pathlib,subprocess,json; p=pathlib.Path(" + repr(remote_work + '/folder') + "); print(json.dumps({str(f.relative_to(p)):subprocess.check_output(['xxhsum','-H1','-q'],input=f.read_bytes()).decode().split()[0] for f in p.rglob('*') if f.is_file()}))"
        actual = json.loads(remote(['python', '-c', code]))
        if actual != expected: raise RuntimeError('physical folder hashes differ')
        evidence['verified_xxh64'] = actual
        evidence['checks'].append('phone pulled file and nested folder; all XXH64 checksums match including empty/unicode files')
        local('revoke', mobile['id'])
        try: phone('roots', laptop['id'])
        except RuntimeError: evidence['checks'].append('revoked phone denied')
        else: raise RuntimeError('revocation failed')
        evidence['result'] = 'PASS'
    except Exception as exc:
        evidence['result'] = 'FAIL'
        evidence['error'] = str(exc)
        raise
    finally:
        if agent is not None:
            agent.terminate()
            try: agent.wait(timeout=8)
            except subprocess.TimeoutExpired: agent.kill(); agent.wait(timeout=3)
            evidence['cleanup'] = 'owned laptop agent stopped; no phone daemon started'
        log.close()
        evidence['agent_stderr'] = (work / 'agent.stderr').read_text()
        output = root / 'docs/test-evidence' / ('physical-lan-' + run + '.json')
        output.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + '\n')
        print(str(output))
        print(evidence['result'])


if __name__ == '__main__': main()
