"""Processed track graphs from session-owned renders. No API or DAW access."""
import fcntl
import json
import math
from pathlib import Path
import re
import time

SCOPE = 'Solo-in-place contribution including routing, shared returns and master FX'


def render_path(directory, name):
    if not isinstance(name, str) or not re.fullmatch(r'render-[\w-]+\.wav', name):
        raise ValueError('Invalid saved track render')
    directory = Path(directory).resolve()
    path = (directory / name).resolve(strict=True)
    if path.parent != directory:
        raise ValueError('Track render must belong to this session')
    return path


def record(directory, path, profile, name, measured_at=None, origin='AI measurement', pass_id=None):
    import worker
    from visuals import mix_graphics
    directory = Path(directory)
    path = render_path(directory, Path(path).name)
    bounds = profile['measurement_bounds']
    if len(bounds) != 2 or any(not isinstance(x, (int, float)) or not math.isfinite(x) for x in bounds) or bounds[1] <= bounds[0]:
        raise ValueError('Invalid track measurement bounds')
    if abs(profile['duration_seconds'] - (bounds[1] - bounds[0])) > .1:
        raise ValueError('Track render was incomplete or has different bounds')
    if profile.get('loudness', {}).get('integrated_lufs') is None:
        raise ValueError('Track render has no measurable audio; existing graphs were preserved')
    track = profile['track']
    if not isinstance(track, str) or not track or track == 'MASTER':
        raise ValueError('Choose an individual track')
    measured_at = time.time() if measured_at is None else measured_at
    full = bounds == worker.read(directory / 'snapshot.json', {}).get('bounds')
    key = track + (':full' if full else ':excerpt')
    profile = dict(profile, title=name + ' · processed track')
    # A mix worker and a local graph job may both publish: keep the newest
    # full passage and excerpt for each GUID, never an index or track-name key.
    with (directory / 'track-graphics.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        graphics = mix_graphics(path, profile, [], directory / 'visuals')
        entry = {'key': key, 'track': track, 'name': name, 'render': path.name,
                 'bounds': bounds, 'full_passage': full, 'measured_at': measured_at,
                 'origin': origin, 'pass_id': pass_id, 'scope': profile.get('scope', SCOPE),
                 'views': graphics['views']}
        manifest = worker.read(directory / 'track-graphics.json', {'version': 1, 'tracks': []})
        previous = next((r for r in manifest['tracks'] if r['key'] == key), None)
        if previous is None or previous['measured_at'] <= measured_at:
            manifest['tracks'] = [r for r in manifest['tracks'] if r['key'] != key] + [entry]
            manifest['tracks'].sort(key=lambda r: (r['name'].casefold(), not r['full_passage'], r['track']))
            worker.write(directory / 'track-graphics.json', manifest)
    return entry


def analyze_saved(directory, item):
    import worker
    directory = Path(directory)
    path = render_path(directory, item['render'])
    profile = worker.analyze_audio(path, directory, item['name'])
    profile.update(track=item['track'], measurement_bounds=item['bounds'], scope=item.get('scope', SCOPE))
    return record(directory, path, profile, item['name'], item.get('measured_at'),
                  item.get('origin', 'Saved measurement'), item.get('pass_id'))


def backfill(directory):
    """Latest full passage AND latest diagnostic per track; never rebounce audio."""
    import worker
    directory = Path(directory)
    bounds = worker.read(directory / 'snapshot.json')['bounds']
    names = {}; latest = {}
    with (directory / 'events.jsonl').open() as source:
        for line in source:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue  # An active worker may be halfway through an append.
            if event.get('kind') == 'bridge_response' and event.get('tool') == 'inspect_project':
                for row in event.get('response', {}).get('result', {}).get('tracks', []):
                    names[row['id']] = row['name']
            if event.get('kind') == 'measurement' and event.get('track'):
                latest[(event['track'], event.get('bounds') == bounds)] = event
    completed = []; errors = []
    for (track, _), item in latest.items():
        try:
            entry = analyze_saved(directory, {'track': track, 'name': names.get(track, 'Track ' + track),
                'render': item['render'], 'bounds': item['bounds'], 'measured_at': item['time'],
                'pass_id': item.get('pass_id'), 'origin': 'Saved AI measurement'})
            completed.append(entry['key'])
        except (OSError, ValueError) as error:
            errors.append({'track': track, 'message': str(error)})
    # Native/manual captures are already published; rebuilding saved AI data
    # cannot replace a newer manual capture because record checks timestamps.
    if not completed and not worker.read(directory / 'track-graphics.json', {}).get('tracks'):
        raise ValueError('No saved track renders are available. Choose Render track… first.')
    return {'state': 'ready', 'completed': completed, 'errors': errors}


def run(directory, capture=False):
    import worker
    directory = Path(directory)
    status = directory / 'track-graphics-status.json'
    with (directory / 'track-graph-job.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        try:
            worker.write(status, {'state': 'running'})
            if capture:
                entry = analyze_saved(directory, worker.read(directory / 'track-graphics-request.json'))
                result = {'state': 'ready', 'selected': entry['key']}
            else:
                result = backfill(directory)
            worker.write(status, result)
            return result
        except Exception as error:
            worker.write(status, {'state': 'error', 'message': str(error)})
            raise
