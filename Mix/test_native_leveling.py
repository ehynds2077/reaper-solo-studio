"""Full leveling loop on a quiet/loud/quiet synthetic guitar. No network/model."""
import json
from pathlib import Path
import sys
import worker


def main(directory):
    session = worker.Session(directory)
    rounds = []
    def api(route, payload):
        rounds.append(payload)
        track = session.project['tracks'][0]['id']
        if len(rounds) == 1:
            calls = [('analyze_track_levels', {'tracks': [track]})]
        elif len(rounds) == 2:
            calls = [('set_trim_automation', {'track': track, 'points': [
                {'seconds': 0, 'db': 0}, {'seconds': 7.9, 'db': 0},
                {'seconds': 8.05, 'db': -6.0206}, {'seconds': 15.95, 'db': -6.0206},
                {'seconds': 16.1, 'db': 0}, {'seconds': 24, 'db': 0}]}),
                ('analyze_track_levels', {'tracks': [track], 'stage': 'verify'}),
                ('review_level_balance', {'track': track, 'decision': 'automated',
                 'reason': 'Reduced the loud 8-16 second phrase by 6.02 dB with short ramps; remeasured all 24 seconds.'})]
        else:
            return {'choices': [{'message': {'role': 'assistant', 'content': 'Synthetic level rides measured and verified.'}}]}
        return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
            {'id': str(i), 'function': {'name': name, 'arguments': json.dumps(args)}}
            for i, (name, args) in enumerate(calls)]}}]}
    session.api = api
    assert session.run() == 'review', worker.read(directory / 'status.json')
    assert len(rounds) == 3
    before = next(json.loads(row['content']) for row in rounds[1]['messages']
                  if row['role'] == 'tool' and 'reports' in json.loads(row['content']))['reports'][0]
    after = next(iter(session.level_reports.values()))['report']
    assert before['active_rms_p90_minus_p10_db'] > 5.8, before
    assert after['active_rms_p90_minus_p10_db'] < .3, after
    assert not session.leveling_issues(), session.leveling_issues()
    worker.write(directory / 'test-result.json', {'ok': True,
        'before_spread_db': before['active_rms_p90_minus_p10_db'],
        'after_spread_db': after['active_rms_p90_minus_p10_db']})


if __name__ == '__main__':
    directory = Path(sys.argv[1])
    try:
        main(directory)
    except Exception as error:
        worker.write(directory / 'test-result.json', {'error': str(error)})
