"""Called only by the silent, disposable REAPER batch fixture; no model/API calls."""
from pathlib import Path
import sys
import worker


def main(directory):
    session = worker.Session(directory)
    project = session.execute_tool('inspect_project', {})
    tracks = project['tracks']
    assert len(tracks) == 10
    plugin = next(name for name in project['available_plugins'] if 'ReaEQ' in name)
    operations = []
    for index, track in enumerate(tracks):
        operations.extend([
            {'tool': 'set_track_mix', 'arguments': {'track': track['id'], 'volume_db': -6, 'pan': 0}},
            {'tool': 'add_effect', 'save_as': 'eq%d' % index,
             'arguments': {'track': track['id'], 'plugin': plugin}},
            {'tool': 'configure_eq', 'arguments': {'track': track['id'], 'effect': '$eq%d' % index,
             'band': 'bell', 'band_index': 0, 'frequency_hz': 300, 'gain_db': -4}},
        ])
    result = session.execute_tool('apply_mix_batch', {'operations': operations})
    assert result.get('completed') == 30, result
    assert len(result['effects']) == 10
    effects = session.execute_tool('inspect_effects', {'effects': list(result['effects'].values())})
    assert all(row['result'].get('parameters') for row in effects['effects']), effects
    comparison = session.execute_tool('measure_tracks', {'tracks': [t['id'] for t in tracks[:2]]})
    assert len(comparison['summary']) == 2 and not comparison['errors'], comparison
    assert all(row['loudness']['integrated_lufs'] is not None for row in comparison['summary'])
    again = session.execute_tool('measure_tracks', {'tracks': [t['id'] for t in tracks[:2]]})
    assert len(again['summary']) == 2 and all(row['reused'] for row in session.timings[-2:])
    worker.write(directory / 'test-result.json', {'ok': True, 'edits': 30, 'effects': 10,
                 'inspected': len(effects['effects']), 'measured': 2, 'repeated_measurements_cached': True})


if __name__ == '__main__':
    directory = Path(sys.argv[1])
    try:
        main(directory)
    except Exception as error:
        worker.write(directory / 'test-result.json', {'error': str(error)})
