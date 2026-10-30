#Run on a disposable, already-rented lob-boss instance; fetch outputs and release it.
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / 'build/art-models'
API = 'https://console.vast.ai/api/v0/instances/'


def api(method, iid, key, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = Request(API + str(iid) + '/', method=method, data=body,
                  headers={'Authorization': 'Bearer ' + key,
                           'Content-Type': 'application/json'})
    with urlopen(req, timeout=30) as response:
        return json.load(response)


def interrupt(signum, frame):
    raise KeyboardInterrupt('Stopping job controller')


def ssh_options(key):
    return ['-i', str(key), '-o', 'IdentitiesOnly=yes',
            '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'UserKnownHostsFile=' + str(WORK / 'known_hosts')]


def run(cmd, seconds, log=None):
    subprocess.run(cmd, check=True, timeout=max(1, seconds),
                   stdout=log, stderr=subprocess.STDOUT if log else None)


def connect(instance, args):
    host = 'root@' + instance['ssh_host']
    port = str(instance['ssh_port'])
    opts = ssh_options(args.ssh_key)
    return ['ssh', *opts, '-p', port, host], ['scp', *opts, '-P', port], host


def verify(out):
    manifest = json.loads((out / 'generation.json').read_text())
    if not manifest['sha256']:
        raise RuntimeError('Worker returned no generated models')
    for name, digest in manifest['sha256'].items():
        if Path(name).name != name:
            raise RuntimeError('Unexpected result filename')
        data = (out / name).read_bytes()
        if data[:4] != b'glTF' or hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError('Model verification failed: ' + name)
    print('VERIFIED', ', '.join(manifest['sha256']), flush=True)


def release(iid, key):
    #Never treat a failed deletion as success: storage still bills when stopped.
    for attempt in range(3):
        try:
            result = api('DELETE', iid, key)
            if result.get('success') is True:
                print('INSTANCE_DESTROYED', iid, flush=True)
                return
        except Exception as error:
            print('Cleanup error:', str(error), flush=True)
        time.sleep(3)
    raise RuntimeError('Could not confirm destruction of instance %d. Check Vast now.' % iid)


def execute(instance, args, key):
    ssh, scp, host = connect(instance, args)
    out = ROOT / 'tools/art/source/helmeted_lizard' / ('vast_%d' % args.instance)
    out.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + args.minutes * 60
    finished = False
    try:
        run([*scp, str(args.bundle), host + ':/workspace/boss-job.tar.gz'], 180)
        run([*ssh, 'tar -xzf /workspace/boss-job.tar.gz -C /workspace'], 30)
        with (out / 'worker.log').open('w') as log:
            run([*ssh, 'cd /workspace/boss-job && bash run_job.sh'],
                deadline - time.monotonic(), log)
        finished = True
    finally:
        try:
            run([*scp, '-r', host + ':/workspace/boss-job/output/.', str(out)], 180)
            if finished:
                verify(out)
        except Exception:
            api('PUT', args.instance, key, {'state': 'stopped'})
            print('RECOVERY_NEEDED: compute stopped; remote files retained. '
                  'Disk still bills until the instance is destroyed.', flush=True)
            raise
        release(args.instance, key)
    print('RESULTS', out, flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('instance', type=int)
    p.add_argument('--key-file', type=Path)
    p.add_argument('--ssh-key', type=Path, default=Path.home() / '.ssh/id_ed25519')
    p.add_argument('--minutes', type=int, default=90)
    p.add_argument('--bundle', type=Path, default=WORK / 'boss-job.tar.gz')
    p.add_argument('--inspect', action='store_true')
    args = p.parse_args()
    if not 1 <= args.minutes <= 90:
        p.error('Use a runtime limit between 1 and 90 minutes.')
    key = (args.key_file.read_text().strip() if args.key_file
           else os.environ.get('VAST_API_KEY', '').strip())
    if not key:
        saved = Path.home() / '.config/vastai/vast_api_key'
        if saved.exists():
            key = saved.read_text().strip()
    if not key:
        p.error('Vast credentials are missing; no API request sent.')
    instance = api('GET', args.instance, key)['instances']
    if not instance.get('label', '').startswith('lob-boss-'):
        p.error('Refusing to touch an instance not labelled for this disposable boss job.')
    print('INSTANCE', args.instance, instance.get('actual_status'), flush=True)
    if args.inspect:
        return
    if instance.get('actual_status') != 'running':
        p.error('Wait for the instance to be running before starting this controller.')
    if not args.bundle.is_file():
        p.error('Create the job bundle with pack_job.py first.')
    signal.signal(signal.SIGTERM, interrupt)
    execute(instance, args, key)


if __name__ == '__main__':
    main()
