"""Scripted model for the disposable native render-recovery fixture; no network."""
import json
from pathlib import Path
import sys
import worker


def main(directory):
    session = worker.Session(directory)
    rounds = []

    def api(route, payload):
        rounds.append(payload)
        if len(rounds) == 1:
            track = session.project['tracks'][0]['id']
            calls = [('set_track_mix', {'track': track, 'volume_db': -3, 'pan': 0}),
                     ('measure_mix', {'full_passage': True})]
            return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                {'id': str(i), 'function': {'name': name, 'arguments': json.dumps(args)}}
                for i, (name, args) in enumerate(calls)]}}]}
        return {'choices': [{'message': {'role': 'assistant', 'content': 'Done.'}}]}

    session.api = api
    state = session.run()
    assert state == 'review', worker.read(directory / 'status.json')
    assert len(rounds) == 2
    assert session.measurement_error is None
    assert all(p['loudness']['integrated_lufs'] is not None for p in session.measurements)
    assert sum(t.get('valid') is False for t in session.timings) == 1
    assert any(t.get('recovered') for t in session.timings)
    assert len(session.analysis_cache) == 1
    assert worker.read(directory / 'failed-measurement.json')['reason'] == 'silent_or_unmeasurable'
    worker.write(directory / 'test-result.json', {'ok': True})


if __name__ == '__main__':
    directory = Path(sys.argv[1])
    try:
        main(directory)
    except Exception as error:
        worker.write(directory / 'test-result.json', {'error': str(error)})
