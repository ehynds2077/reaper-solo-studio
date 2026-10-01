"""Native MCP test worker: real analyzer and REAPER bridge, no provider calls."""
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Mix'))
import worker

directory = Path(sys.argv[1])


def scripted_api(route, payload):
    if worker.read(directory / 'config.json').get('resume'):
        # Keep the test worker in an interruptible API-like phase for the guard
        # and cancellation checks; never read credentials or send a request.
        deadline = time.monotonic() + 25
        while not (directory / 'cancel').exists() and time.monotonic() < deadline:
            time.sleep(.1)
    return {'choices': [{'message': {'role': 'assistant', 'content': 'Synthetic mix checked.'}}]}


worker.run_session(directory, api=scripted_api)
