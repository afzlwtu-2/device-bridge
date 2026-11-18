#!/usr/bin/env python3
"""Package already-built outputs; fail if an APK contains an outdated Go core."""
from checksums import xxh64, xxh64_bytes
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile


def main():
    root=Path(__file__).resolve().parent.parent
    apk=root/'app/build/app/outputs/flutter-apk/app-release.apk'
    core=(root/'artifacts/android-arm64/libbridge_cli.so').read_bytes()
    with zipfile.ZipFile(apk) as z:
        if z.read('lib/arm64-v8a/libbridge_cli.so')!=core:
            raise RuntimeError('APK Go core differs from NDK build; rebuild the APK before packaging')
    out=root/'artifacts/android-arm64/devicebridge.apk'
    shutil.copy2(apk,out)
    if xxh64(apk) != xxh64(out):
        raise RuntimeError('Completed APK copy failed XXH64 verification')
    linux=root/'artifacts/linux/devicebridge-linux-x64.tar.gz'
    bundle=root/'app/build/linux/x64/release/bundle'
    with tarfile.open(linux,'w:gz') as archive:
        archive.add(bundle,arcname='devicebridge')
    files=[out,linux,root/'artifacts/linux/bridge-agent',root/'artifacts/linux/bridge-cli']
    debug=root/'artifacts/android-arm64/devicebridge-debug.apk'
    if debug.exists():
        with zipfile.ZipFile(debug) as z:
            if z.read('lib/arm64-v8a/libbridge_cli.so')!=core:
                raise RuntimeError('Debug APK contains an outdated Go core')
        files.append(debug)
    termux=[root/'artifacts/termux-arm64/bridge-agent',root/'artifacts/termux-arm64/bridge-cli']
    files.extend(p for p in termux if p.exists())
    manifest={'files':{str(p.relative_to(root)):{'bytes':p.stat().st_size,'xxh64':xxh64(p)} for p in files},'android_signing':'development key; optimized build','core_xxh64':xxh64_bytes(core)}
    listed=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=root).split(b'\0')
    source_records=bytearray()
    for name in sorted(set(listed)):
        if not name:continue
        relative=name.decode();p=root/relative
        if relative.startswith(('docs/','artifacts/','.work/')) or not p.is_file():continue
        source_records.extend(name+b'\0'+bytes.fromhex(xxh64(p)))
    manifest['source_xxh64_excluding_docs_artifacts']=xxh64_bytes(source_records)
    manifest['termux_artifacts_not_built']=[str(p.relative_to(root)) for p in termux if not p.exists()]
    (root/'artifacts/MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (root/'docs/test-evidence/artifact-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest,indent=2))


if __name__=='__main__':main()
