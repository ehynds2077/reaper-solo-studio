"""Local bounce archive and macOS audition helper. No network access or uploads."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import wave


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    tmp.replace(path)


FILE_LINE = re.compile(r'^(\s*FILE\s+)(?:"([^"]*)"|\x27([^\x27]*)\x27|`([^`]*)`|(\S+))(.*)$')


def source_files(text):
    """Only item/freeze SOURCE filenames, never opaque plugin chunks or notes."""
    stack = []
    for index, line in enumerate(text.splitlines(keepends=True)):
        stripped = line.strip()
        if stripped.startswith('<'):
            stack.append(stripped[1:].split()[0])
        elif stripped == '>':
            if stack:
                stack.pop()
        elif 'SOURCE' in stack:
            match = FILE_LINE.match(line.rstrip('\r\n'))
            if match:
                yield index, match, next(x for x in match.groups()[1:5] if x is not None)


def preserve_source(path, pool):
    path = Path(path)
    if not path.is_file():
        raise ValueError('A session recording is missing: ' + path.name)
    before = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    extension = path.suffix.lower()
    if not re.fullmatch(r'\.[a-z0-9]{1,12}', extension):
        extension = '.media'
    target = pool / (digest.hexdigest() + extension)
    if not target.exists():
        # Real copies, never hard links: editing/deleting the original cannot
        # damage saved versions. Identical sources are shared across bounces.
        with tempfile.NamedTemporaryFile(dir=pool, delete=False) as output:
            temporary = Path(output.name)
        try:
            shutil.copyfile(path, temporary)
            copied = hashlib.sha256()
            with temporary.open('rb') as source:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    copied.update(block)
            if copied.hexdigest() != digest.hexdigest():
                raise ValueError('A recording changed while archiving. Retry the export.')
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    if path.stat().st_mtime_ns != before.st_mtime_ns or path.stat().st_size != before.st_size:
        raise ValueError('A recording changed while archiving. Retry the export.')
    return target


def archive_session(snapshot, pool, memo):
    snapshot = Path(snapshot)
    text = snapshot.read_text(); lines = text.splitlines(keepends=True)
    if '<SOURCE RPP_PROJECT' in text:
        raise ValueError('Subprojects need their own archive; nested project exports are not supported yet.')
    count = 0
    for index, match, name in source_files(text):
        path = Path(name)
        if not path.is_absolute():
            path = snapshot.parent / path
        path = path.resolve()
        if not path.is_file():
            raise ValueError('Snapshot recording is missing: ' + path.name)
        if path not in memo:
            memo[path] = preserve_source(path, pool)
        relative = os.path.relpath(memo[path], snapshot.parent)
        ending = '\r\n' if lines[index].endswith('\r\n') else '\n'
        lines[index] = match.group(1) + '"' + relative + '"' + match.group(6) + ending
        count += 1
    temporary = snapshot.with_suffix('.RPP.tmp')
    temporary.write_text(''.join(lines)); temporary.replace(snapshot)
    return count


def ffmpeg_path():
    found = shutil.which('ffmpeg')
    if found:
        return found
    for candidate in ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']:
        if Path(candidate).is_file():
            return candidate
    raise ValueError('FFmpeg is required to create M4A phone copies. Install it, then Retry archive.')


def archive(folder):
    with (Path(folder) / '.archive.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # A previous click is already packaging this version.
        _archive(folder)


def _archive(folder):
    folder = Path(folder).resolve()
    status = folder / 'status.json'
    try:
        manifest = read(folder / 'bounce.json')
        if manifest.get('state') not in ('packaging', 'failed', 'ready'):
            raise ValueError('Finish both renders before archiving.')
        write(status, {'state': 'packaging', 'message': 'Preserving source recordings…'})
        pool = folder.parent / '_Media'; pool.mkdir(exist_ok=True)
        memo = {}; sources = 0
        for name in ['Session.RPP', 'Instrumental session.RPP']:
            sources += archive_session(folder / name, pool, memo)
        encoder = ffmpeg_path()
        duration = None
        phone_names = {}
        prefix = re.sub(r'[\x00-\x1f/\\:*?"<>|]', '-', manifest['project_title'] + ' - ' + manifest['title'])[:160]
        for name in ['Full mix', 'Instrumental']:
            with wave.open(str(folder / (name + '.wav'))) as audio:
                seconds = audio.getnframes() / audio.getframerate()
                if seconds + .05 < manifest['bounds'][1] - manifest['bounds'][0] + manifest.get('tail_seconds', 0):
                    raise ValueError('An audio render is incomplete. Bounce this version again.')
                if duration is not None and abs(seconds - duration) > .05:
                    raise ValueError('The full and instrumental renders have different lengths.')
                duration = seconds
            write(status, {'state': 'packaging', 'message': 'Creating ' + name.lower() + ' for your phone…'})
            temporary = folder / (name + '.tmp.m4a')
            result = subprocess.run([encoder, '-nostdin', '-v', 'error', '-y', '-i', str(folder / (name + '.wav')),
                                     '-vn', '-c:a', 'aac', '-b:a', '256k', '-movflags', '+faststart', str(temporary)],
                                    capture_output=True, timeout=1800)
            if result.returncode:
                raise ValueError('M4A conversion failed: ' + result.stderr.decode(errors='replace')[-400:])
            phone_names[name] = prefix + ' - ' + name + '.m4a'
            temporary.replace(folder / phone_names[name])
        manifest.update(state='ready', duration=duration, media_references=sources,
                        phone_full=phone_names['Full mix'], phone_instrumental=phone_names['Instrumental'])
        write(folder / 'bounce.json', manifest)
        (folder / 'Read me.txt').write_text(
            manifest['project_title'] + ' — ' + manifest['title'] + '\n\n' + manifest.get('notes', '') +
            '\n\nText or AirDrop the named M4A full mix and instrumental files to your phone.\n'
            'The WAVs are stereo 48 kHz / 24-bit archives with a two-second tail.\n'
            'Open Session.RPP in REAPER to return to this full mix; Instrumental session.RPP has the vocals muted.\n'
            'Recordings are preserved in the shared _Media folder beside your versions.\n'
            'Keep the entire Solo Studio Mixes folder together when moving/backing it up.\n'
            'Installed plugins, licenses, and plugin sample libraries are still required.\n')
        write(status, {'state': 'ready', 'message': 'Full mix, instrumental, and session copies saved.'})
    except Exception as error:
        write(status, {'state': 'failed', 'message': str(error)})
        raise


def preview(folder):
    """An owned afplay process; never signal an arbitrary PID supplied by a file."""
    folder = Path(folder); request = read(folder / 'request.json')
    path = Path(request['path']).resolve()
    process = None; elapsed = 0.; mark = time.monotonic(); paused = False
    try:
        if read(folder / 'control.json').get('state') == 'stop' or time.time() - (folder / 'lease').stat().st_mtime > 8:
            write(folder / 'status.json', {'state': 'stopped', 'position': 0})
            return
        process = subprocess.Popen(['/usr/bin/afplay', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        while process.poll() is None:
            control = read(folder / 'control.json')
            if control.get('state') == 'stop' or time.time() - (folder / 'lease').stat().st_mtime > 8:
                break
            desired_pause = control.get('state') == 'paused'
            now = time.monotonic()
            if not paused:
                elapsed += now - mark
            mark = now
            if desired_pause != paused:
                process.send_signal(signal.SIGSTOP if desired_pause else signal.SIGCONT)
                paused = desired_pause
            write(folder / 'status.json', {'state': 'paused' if paused else 'playing', 'position': elapsed})
            time.sleep(.15)
        if process.poll() not in (None, 0):
            raise ValueError('macOS could not play this file. Check the Mac audio output.')
        write(folder / 'status.json', {'state': 'stopped', 'position': elapsed})
    except Exception as error:
        write(folder / 'status.json', {'state': 'failed', 'message': str(error)})
    finally:
        if process and process.poll() is None:
            process.send_signal(signal.SIGCONT); process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['archive', 'preview']); parser.add_argument('folder')
    args = parser.parse_args()
    if args.action == 'archive':
        archive(args.folder)
    else:
        preview(args.folder)
