"""Prepare a private, inspectable Live-to-REAPER import. Never edits source files."""
from __future__ import annotations
import argparse
import bisect
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import traceback
from als import read_set, inventory, value, number, boolean, plugin_description


def atomic_json(path, data):
    path = Path(path)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    temp.replace(path)


def target(node, path):
    e = node.find(path + '/AutomationTarget') if node is not None else None
    return e.get('Id') if e is not None else ''


def events(envelope):
    result = []
    for e in envelope.findall('Automation/Events/*'):
        raw = e.get('Value', '0')
        v = {'true': 1, 'false': 0}.get(raw)
        v = float(raw) if v is None else v
        raw_beat = float(e.get('Time', 0))
        beat = max(0, raw_beat)
        if not math.isfinite(beat) or not math.isfinite(v):
            raise ValueError('Non-finite automation value')
        result.append({'beat': beat, 'value': v, 'step': e.tag != 'FloatEvent' or raw_beat < -1000000,
                       'initial': raw_beat < -1000000,
                       'curve': {k: v for k, v in e.attrib.items() if k.startswith('Curve')}})
    # Live's initial-value sentinel and a real event at zero: the latter wins.
    return list({e['beat']: e for e in sorted(result, key=lambda e: e['beat'])}.values())


def signature(n):
    # Live enumerates numerators 1..99 for each power-of-two denominator.
    n = int(n)
    return n % 99 + 1, 2 ** (n // 99)


class Tempo:
    def __init__(self, bpm, points=()):
        points = list(points) or [{'beat': 0, 'value': bpm}]
        if points[0]['beat'] > 0:
            points.insert(0, {'beat': 0, 'value': bpm})
        self.points = points
        self.times = [0.0]
        for a, b in zip(points, points[1:]):
            if not 1 <= a['value'] <= 1000 or not 1 <= b['value'] <= 1000:
                raise ValueError('Invalid tempo')
            self.times.append(self.times[-1] + self.duration(a, b, b['beat'] - a['beat']))
        self.beats = [p['beat'] for p in points]

    @staticmethod
    def duration(a, b, beats):
        slope = 0 if a.get('step') else (b['value']-a['value']) / (b['beat']-a['beat'])
        return 60 * math.log((a['value'] + slope * beats)/a['value']) / slope if abs(slope) > 1e-12 else 60 * beats / a['value']

    def seconds(self, beat):
        i = max(0, bisect.bisect_right(self.beats, beat) - 1)
        a = self.points[i]
        if i + 1 == len(self.points):
            return self.times[i] + 60 * (beat-a['beat']) / a['value']
        return self.times[i] + self.duration(a, self.points[i+1], beat-a['beat'])

    def markers(self):
        result = []
        for i, a in enumerate(self.points):
            if i+1 < len(self.points) and a['value'] != self.points[i+1]['value'] and not a.get('step'):
                b = self.points[i+1]
                # Exact elapsed time at each subdivision; REAPER's tempo ramps use
                # a different independent variable from Live's beat-domain ramps.
                count = max(1, math.ceil((b['beat']-a['beat']) * 16))
                if count > 100000:
                    raise ValueError('Tempo ramp exceeds import subdivision limit')
                for n in range(count):
                    x = a['beat'] + (b['beat']-a['beat']) * n/count
                    y = a['beat'] + (b['beat']-a['beat']) * (n+1)/count
                    result.append({'time': self.seconds(x), 'bpm': 60*(y-x)/(self.seconds(y)-self.seconds(x))})
            else:
                result.append({'time': self.seconds(a['beat']), 'bpm': a['value']})
        return result


def warp_seconds(markers, beat, bpm):
    if len(markers) < 2:
        return beat * 60/bpm
    i = max(0, min(len(markers)-2, bisect.bisect_right([m[0] for m in markers], beat)-1))
    a, b = markers[i:i+2]
    if b[0] <= a[0]:
        raise ValueError('Duplicate or reversed warp marker')
    return a[1] + (beat-a[0]) * (b[1]-a[1])/(b[0]-a[0])


def segments(start, end, offset, loop_start, loop_end, loop_on):
    """Arrangement beats plus source-domain offset; split loop wraps explicitly."""
    if end <= start:
        return
    if not loop_on or loop_end <= loop_start:
        yield start, end, offset
        return
    count = 0
    while start < end-1e-9:
        if offset >= loop_end:
            offset = loop_start + (offset-loop_start) % (loop_end-loop_start)
        stop = min(end, start+loop_end-offset)
        yield start, stop, offset
        offset = loop_start
        start = stop
        count += 1
        if count > 100000:
            raise ValueError('Clip loop expansion exceeds safety limit')


class Media:
    def __init__(self, source, extra_roots=(), index=None):
        self.source = source
        self.by_name = collections.defaultdict(list)
        for name, paths in (index or {}).items():
            self.by_name[name].extend(paths)
        # Bounded to this project and folders explicitly supplied by the caller.
        roots = [source.parent] + [Path(p).expanduser() for p in extra_roots]
        for root in roots:
            for folder, dirs, files in os.walk(root):
                dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', 'Backup') and not d.startswith('.')]
                for name in files:
                    if Path(name).suffix.lower() in ('.wav', '.aif', '.aiff', '.flac', '.mp3', '.ogg', '.m4a'):
                        self.by_name[name].append(str(Path(folder)/name))
        self.cache = {}

    def resolve(self, clip):
        ref = clip.find('SampleRef/FileRef')
        original = value(ref, 'Path', '')
        relative = value(ref, 'RelativePath', '')
        size = int(number(ref, 'OriginalFileSize'))
        key = (original, relative, size)
        if key in self.cache:
            return self.cache[key]
        candidates = [Path(original)] if original else []
        if relative:
            candidates += [self.source.parent/relative]
        chosen = None
        for p in candidates:
            # Do not trigger cloud hydration during an import. Explicit downloaded
            # copies can be supplied via a relink folder.
            if '/Mobile Documents/' in str(p) or '/CloudStorage/' in str(p):
                continue
            if p.is_file():
                chosen = p.resolve(); break
        matches = []
        if chosen is None:
            for p in self.by_name.get(Path(original or relative).name, []):
                p = Path(p)
                if p.is_file() and (not size or p.stat().st_size == size):
                    matches.append(p.resolve())
            matches = sorted(set(matches))
            # A basename is insufficient when multiple different recordings exist.
            if len(matches) == 1:
                chosen = matches[0]
            elif matches:
                hashes = {hashlib.sha256(p.read_bytes()).digest() for p in matches}
                if len(hashes) == 1:
                    chosen = matches[0]
        row = {'original': original, 'relative': relative, 'path': str(chosen) if chosen else '',
               'status': 'found' if chosen else 'ambiguous' if matches else 'missing',
               'candidates': [str(p) for p in matches], 'bytes': chosen.stat().st_size if chosen else size}
        self.cache[key] = row
        return row


class Import:
    def __init__(self, source, output, extra_roots=(), media_index=None):
        self.source, self.root, _ = read_set(source)
        self.ls = self.root.find('LiveSet')
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        (self.output/'Plugin states').mkdir()
        self.warnings = []
        self.media = Media(self.source, extra_roots, media_index)
        self.serial = 0
        self.targets = {}
        self.main = self.ls.find('MainTrack')
        if self.main is None:
            self.main = self.ls.find('MasterTrack')
        self.bpm = number(self.main, 'DeviceChain/Mixer/Tempo/Manual', 120)
        tid = target(self.main, 'DeviceChain/Mixer/Tempo')
        all_env = self.main.findall('AutomationEnvelopes/Envelopes/AutomationEnvelope')
        tempo = next((events(e) for e in all_env if value(e, 'EnvelopeTarget/PointeeId') == tid), [])
        if len(tempo) > 1 and tempo[0].get('initial') and tempo[0]['value'] != tempo[1]['value']:
            self.warn('tempo-initial-review', 'The pre-roll tempo differs from the first real breakpoint. Initial tempo is held until that breakpoint; verify this unusual envelope against Live before relying on sync.')
        self.tempo = Tempo(self.bpm, tempo)
        if len(tempo) > 1:
            self.warn('tempo-ramp', 'Tempo automation is transferred; changing ramps are subdivided at 1/16 beat.')

    def warn(self, code, message, **details):
        self.warnings.append(dict(code=code, message=message, **details))

    def bind(self, node, path, mapping):
        key = target(node, path)
        if key:
            self.targets[key] = mapping

    def devices(self, parent, track, inherited=True):
        result = []
        if parent is None:
            return result
        for device in parent:
            self.serial += 1
            key = str(self.serial)
            enabled = inherited and boolean(device, 'On/Manual', True)
            desc = plugin_description(device)
            row = {'key': key, 'type': device.tag, 'enabled': enabled,
                   'name': value(device, 'UserName', '') or (desc['name'] if desc else device.tag)}
            self.bind(device, 'On', {'kind': 'bypass', 'track': track, 'device': key})
            if desc:
                row['plugin'] = desc
                info = device.find('PluginDesc')[0]
                preset = info.find('Preset')[0]
                state = None
                if desc['kind'] == 'AuPluginInfo':
                    state = bytes.fromhex(''.join((preset.findtext('Buffer') or '').split()))
                    plistlib.loads(state)  # Validate before passing to native host.
                    extension = '.aupreset'
                elif desc['kind'] == 'Vst3PluginInfo':
                    chunks = []
                    payload = b''
                    for tag, code in [('ProcessorState', b'Comp'), ('ControllerState', b'Cont')]:
                        data = bytes.fromhex(''.join((preset.findtext(tag) or '').split()))
                        if data:
                            chunks.append((code, 48+len(payload), len(data))); payload += data
                    state = b'VST3'+struct.pack('<I', 1)+desc['uid'].encode()+struct.pack('<Q', 48+len(payload))+payload
                    state += b'List'+struct.pack('<I', len(chunks))+b''.join(c+struct.pack('<QQ', a, b) for c, a, b in chunks)
                    extension = '.vstpreset'
                elif desc['kind'] == 'VstPluginInfo':
                    state = bytes.fromhex(''.join((preset.findtext('Buffer') or '').split()))
                    extension = '.vstchunk'
                if state:
                    path = self.output/'Plugin states'/(key+extension)
                    path.write_bytes(state); row['state'] = str(path)
                else:
                    self.warn('plugin-state', 'No supported saved state was found.', track=track, device=row['name'])
                row['parameters'] = []
                for p in device.findall('ParameterList/*') + device.findall('PluginParameterList/*'):
                    pid = value(p, 'ParameterId', '-1')
                    if pid == '-1':
                        continue
                    scale = 1/max(1, number(p, 'LastItemCount', 2)-1) if p.tag == 'PluginEnumParameter' else 1
                    row['parameters'].append({'id': pid, 'name': value(p, 'ParameterName', ''),
                                              'value': number(p, 'ParameterValue/Manual') * scale})
                    self.bind(p, 'ParameterValue', {'kind': 'parameter', 'track': track, 'device': key, 'parameter': pid, 'scale': scale})
                result.append(row)
            elif device.tag == 'AudioEffectGroupDevice':
                branches = device.findall('Branches/AudioEffectBranch')
                neutral = len(branches) == 1 and number(branches[0], 'MixerDevice/Volume/Manual', 1) == 1 and number(branches[0], 'MixerDevice/Panorama/Manual') == 0
                if neutral:
                    branch = branches[0]
                    children = self.devices(branch.find('DeviceChain/AudioToAudioDeviceChain/Devices'), track,
                                            enabled and boolean(branch, 'MixerDevice/Speaker/Manual', True))
                    result.extend(children)
                    self.targets[target(device, 'On')] = {'kind': 'rack-bypass', 'track': track, 'devices': [d['key'] for d in children]}
                    self.warn('rack-flattened', 'A single unity-gain audio rack chain is expanded in its original order. Macro mappings remain in the XML archive.', track=track, device=row['name'])
                else:
                    row['unsupported'] = True; result.append(row)
                    self.warn('rack', 'Parallel or non-unity rack requires an Ableton render; complete rack state is archived.', track=track, device=row['name'])
            else:
                row['unsupported'] = device.tag != 'Tuner'
                result.append(row)
                if row['unsupported']:
                    self.warn('live-device', 'Live-native DSP has no exact REAPER equivalent. Retained as a labeled bypassed placeholder; render/freeze in Live for the original sound.', track=track, device=row['name'])
        return result

    def clip(self, c, lane, context, cc_targets):
        start = number(c, 'CurrentStart', float(c.get('Time', 0)))
        end = number(c, 'CurrentEnd', start)
        if context == 'session':
            start = 0; end = number(c, 'Loop/LoopEnd')-number(c, 'Loop/LoopStart')
        if end <= start:
            return []
        if start < 0:
            self.warn('negative-clip', 'Clip begins before project zero and is trimmed at zero.', clip=value(c, 'Name'))
        loop_start = number(c, 'Loop/LoopStart')
        offset = loop_start + number(c, 'Loop/StartRelative')
        loop_end = number(c, 'Loop/LoopEnd', end-start)
        loop_on = boolean(c, 'Loop/LoopOn')
        warped = boolean(c, 'IsWarped')
        common = {'name': value(c, 'Name', 'Live clip'), 'lane': lane, 'context': context,
                  'source_id': c.get('Id'), 'take_id': value(c, 'TakeId', ''),
                  'muted': boolean(c, 'Disabled'), 'notes': value(c, 'Annotation', ''),
                  'gain': number(c, 'SampleVolume', 1), 'pitch': number(c, 'PitchCoarse')+number(c, 'PitchFine')/100}
        if value(c, 'GrooveSettings/GrooveId', '-1') != '-1':
            self.warn('groove', 'Groove is archived; commit it in Live for exact timing.', clip=common['name'])
        envelopes = c.findall('Envelopes/Envelopes/ClipEnvelope') + c.findall('Envelopes/Envelopes/AutomationEnvelope')
        if c.tag == 'AudioClip':
            media = self.media.resolve(c)
            common.update(kind='audio', media=media['path'], original_media=media['original'], media_status=media['status'], warped=warped)
            markers = sorted([[float(e.get('BeatTime')), float(e.get('SecTime'))] for e in c.findall('WarpMarkers/WarpMarker')])
            common['warp_mode'] = value(c, 'WarpMode')
            if envelopes:
                self.warn('audio-clip-envelopes', 'Audio clip modulation is archived; commit/render in Live for exact modulation.', clip=common['name'], envelopes=len(envelopes))
            if not warped:
                # Unwarped Live loop offsets and lengths are seconds, not beats.
                rate = 2 ** (common['pitch']/12)
                positions = segments(self.tempo.seconds(start)*rate, self.tempo.seconds(end)*rate, offset, loop_start, loop_end, loop_on)
                for a, b, off in positions:
                    a /= rate; b /= rate
                    trim = max(0, -a)
                    if b <= 0:
                        continue
                    yield dict(common, position=max(0, a), length=b-max(0, a), offset=off+trim*rate, stretch=[],
                               fade_in=max(0, self.tempo.seconds(start+number(c, 'Fades/FadeInLength'))-self.tempo.seconds(start)) if a == self.tempo.seconds(start) else 0,
                               fade_out=max(0, self.tempo.seconds(end)-self.tempo.seconds(end-number(c, 'Fades/FadeOutLength'))) if b == self.tempo.seconds(end) else 0)
                return
        positions = segments(start, end, offset, loop_start, loop_end, loop_on)
        for a, b, off in positions:
            if b <= 0:
                continue
            off += max(0, -a); a = max(0, a)
            row = dict(common, position=self.tempo.seconds(a), length=self.tempo.seconds(b)-self.tempo.seconds(a))
            if c.tag == 'AudioClip':
                source_start = warp_seconds(markers, off, self.bpm)
                beats = {a, b}
                beats.update(a+m[0]-off for m in markers if off < m[0] < off+b-a)
                beats.update(p['beat'] for p in self.tempo.points if a < p['beat'] < b)
                row['offset'] = source_start
                row['stretch'] = [[self.tempo.seconds(x)-row['position'], warp_seconds(markers, off+x-a, self.bpm)] for x in sorted(beats)]
                row['fade_in'] = max(0, self.tempo.seconds(a+number(c, 'Fades/FadeInLength'))-self.tempo.seconds(a)) if a == start else 0
                row['fade_out'] = max(0, self.tempo.seconds(b)-self.tempo.seconds(b-number(c, 'Fades/FadeOutLength'))) if b == end else 0
                if any(number(c, 'Fades/'+tag) for tag in ('FadeInCurveSkew', 'FadeOutCurveSkew', 'FadeInCurveSlope', 'FadeOutCurveSlope')):
                    self.warn('fade-curve', 'Fade lengths transfer; custom Live fade curves are approximated by linear fades.', clip=common['name'])
            else:
                row.update(kind='midi', notes_midi=[], cc=[])
                for key in c.findall('Notes/KeyTracks/KeyTrack'):
                    pitch = int(number(key, 'MidiKey'))
                    for n in key.findall('Notes/MidiNoteEvent'):
                        x = float(n.get('Time', 0)); y = x+float(n.get('Duration', 0))
                        if x < off+b-a and y > off:
                            row['notes_midi'].append({'start': self.tempo.seconds(a+max(x, off)-off),
                              'end': self.tempo.seconds(a+min(y, off+b-a)-off), 'pitch': pitch,
                              'velocity': int(float(n.get('Velocity', 100))), 'muted': n.get('IsEnabled') == 'false'})
                        if float(n.get('Probability', 1)) != 1 or float(n.get('VelocityDeviation', 0)) != 0:
                            self.warn('midi-probability', 'MIDI probability/velocity randomization is archived; notes use stored velocity.', clip=common['name'])
                for env in envelopes:
                    pid = value(env, 'EnvelopeTarget/PointeeId')
                    controller = cc_targets.get(pid)
                    if controller is None:
                        self.warn('clip-envelope', 'Unmapped clip envelope is archived.', clip=common['name'], target=pid)
                        continue
                    points = events(env)
                    prior = [e for e in points if e['beat'] <= off]
                    if prior:
                        row['cc'].append({'time': self.tempo.seconds(a), 'controller': controller, 'value': prior[-1]['value']})
                    for e in points:
                        if off < e['beat'] <= off+b-a:
                            row['cc'].append({'time': self.tempo.seconds(a+e['beat']-off), 'controller': controller, 'value': e['value']})
            yield row

    def build(self):
        tracks = list(self.ls.find('Tracks')) + [self.main]
        returns = [t.get('Id') for t in tracks if t.tag == 'ReturnTrack']
        send_ids = [s.get('Id') for s in self.ls.findall('SendsPre/SendPreBool')]
        return_map = dict(zip(send_ids, returns))
        pre = {s.get('Id'): s.get('Value') == 'true' for s in self.ls.findall('SendsPre/SendPreBool')}
        result = []
        for t in tracks:
            main = t is self.main
            tid = 'main' if main else t.get('Id')
            mixer = t.find('DeviceChain/Mixer')
            row = {'id': tid, 'type': t.tag, 'name': value(t, 'Name/EffectiveName', 'Main'),
                   'group': value(t, 'TrackGroupId', '-1'), 'linked_group': value(t, 'LinkedTrackGroupId', '-1'),
                   'volume': number(mixer, 'Volume/Manual', 1), 'pan': number(mixer, 'Pan/Manual'),
                   'pan_mode': number(mixer, 'PanMode'), 'pan_l': number(mixer, 'SplitStereoPanL/Manual', -1),
                   'pan_r': number(mixer, 'SplitStereoPanR/Manual', 1), 'muted': not boolean(mixer, 'Speaker/Manual', True),
                   'solo': boolean(mixer, 'SoloSink'), 'delay': number(t, 'TrackDelay/Value'),
                   'delay_samples': boolean(t, 'TrackDelay/IsValueSampleBased'),
                   'input': value(t, 'DeviceChain/AudioInputRouting/Target', ''),
                   'output': value(t, 'DeviceChain/AudioOutputRouting/Target', ''),
                   'output_label': value(t, 'DeviceChain/AudioOutputRouting/LowerDisplayString', ''),
                   'midi_output': value(t, 'DeviceChain/MidiOutputRouting/Target', ''),
                   'color': int(number(t, 'Color', -1)), 'sends': [], 'clips': [], 'lanes': ['Comp'],
                   'notes': value(t, 'Name/Annotation', '')}
            for tag, kind in [('Volume', 'volume'), ('Pan', 'pan'), ('Speaker', 'mute'), ('SplitStereoPanL', 'pan_l'), ('SplitStereoPanR', 'pan_r')]:
                self.bind(mixer, tag, {'kind': kind, 'track': tid})
            row['devices'] = self.devices(t.find('DeviceChain/DeviceChain/Devices'), tid)
            for send_position, s in enumerate(mixer.findall('Sends/TrackSendHolder')):
                sid = s.get('Id')
                # Holder IDs can be stale after deleting a return. Their ordered
                # positions correspond to the current ordered return tracks.
                destination = returns[send_position] if send_position < len(returns) else ''
                pre_id = send_ids[send_position] if send_position < len(send_ids) else sid
                row['sends'].append({'id': sid, 'destination': destination, 'pre': pre.get(pre_id, False),
                                     'gain': number(s, 'Send/Manual'), 'enabled': boolean(s, 'EnabledByUser', True)})
                self.bind(s, 'Send', {'kind': 'send', 'track': tid, 'send': sid})
            seq = t.find('DeviceChain/MainSequencer')
            cc_targets = {}
            if seq is not None:
                cc_targets = {e.get('Id'): int(e.tag.split('.')[-1]) for e in seq.findall('MidiControllers/*')}
                for c in seq.findall('Sample/ArrangerAutomation/Events/*') + seq.findall('ClipTimeable/ArrangerAutomation/Events/*'):
                    if c.tag in ('AudioClip', 'MidiClip'):
                        row['clips'].extend(self.clip(c, 0, 'arrangement', cc_targets))
                for lane in t.findall('TakeLanes/TakeLanes/TakeLane'):
                    idx = len(row['lanes']); row['lanes'].append(value(lane, 'Name', '') or 'Live take '+str(idx))
                    for c in lane.findall('ClipAutomation/Events/*'):
                        if c.tag in ('AudioClip', 'MidiClip'):
                            row['clips'].extend(self.clip(c, idx, 'take', cc_targets))
                for slot in seq.findall('ClipSlotList/ClipSlot'):
                    clips = slot.findall('.//AudioClip') + slot.findall('.//MidiClip')
                    if clips:
                        idx = len(row['lanes']); row['lanes'].append('Session slot '+str(int(slot.get('Id', 0))+1))
                        for c in clips:
                            row['clips'].extend(self.clip(c, idx, 'session', cc_targets))
                if t.findall('.//FreezeSequencer//AudioClip'):
                    self.warn('freeze', 'Freeze media is indexed in the XML archive; editable source tracks are imported.', track=tid)
            result.append(row)
        automation = []
        tempo_id = target(self.main, 'DeviceChain/Mixer/Tempo')
        sig_id = target(self.main, 'DeviceChain/Mixer/TimeSignature')
        signatures = [{'time': 0, 'value': number(self.main, 'DeviceChain/Mixer/TimeSignature/Manual', 201)}]
        for t in tracks:
            for env in t.findall('AutomationEnvelopes/Envelopes/AutomationEnvelope'):
                pid = value(env, 'EnvelopeTarget/PointeeId')
                points = events(env)
                if pid == tempo_id:
                    continue
                if pid == sig_id:
                    signatures = [{'time': self.tempo.seconds(e['beat']), 'value': e['value']} for e in points]
                    continue
                mapping = self.targets.get(pid)
                if not mapping:
                    self.warn('automation-target', 'Automation target has no verified mapping; envelope is archived.', target=pid, track=value(t, 'Name/EffectiveName'))
                    continue
                if any(p['curve'] for p in points):
                    self.warn('automation-curve', 'Automation breakpoints transfer; Live curve handles require review.', target=pid)
                automation.append(dict(mapping, points=[dict(p, time=self.tempo.seconds(p['beat'])) for p in points]))
        for s in signatures:
            s['numerator'], s['denominator'] = signature(s.pop('value'))
        locators = sorted([{'time': self.tempo.seconds(number(e, 'Time')), 'name': value(e, 'Name', 'Section')}
                           for e in self.ls.findall('Locators/Locators/Locator')], key=lambda e: e['time'])
        media = list(self.media.cache.values())
        self.warn('warp-engine', 'Warp marker timing transfers. REAPER and Live use different stretching algorithms; compare warped audio by ear.')
        self.warn('monitoring', 'Imported hardware input monitoring and record arming are off. External output assignments require review.')
        plan = {'schema': 1, 'source': str(self.source), 'name': self.source.stem, 'folder': str(self.output),
                'creator': self.root.get('Creator'), 'bpm': self.bpm, 'tempo': self.tempo.markers(),
                'signatures': signatures, 'locators': locators, 'tracks': result, 'automation': automation,
                'media': media, 'warnings': self.warnings,
                'stats': {'tracks': len(result)-1, 'clips': sum(len(t['clips']) for t in result),
                          'missing_media': sum(m['status'] != 'found' for m in media),
                          'missing_arrangement_clips': sum(c.get('media_status', 'found') != 'found' for t in result for c in t['clips'] if c['context'] == 'arrangement')}}
        return plan


def prepare(source, output, extra_roots=(), media_index=None, copy_media=False):
    job = Import(source, output, extra_roots, media_index)
    plan = job.build()
    inventory(source, job.output/'XML inventory')
    if copy_media:
        destination = job.output/'Media'; destination.mkdir()
        needed = sum(m['bytes'] for m in plan['media'] if m['path'])
        if shutil.disk_usage(destination).free < needed + 256*1024*1024:
            raise ValueError('Not enough free space to copy referenced audio')
        copied = {}
        for m in plan['media']:
            if m['path']:
                original = m['path']
                if original not in copied:
                    name = hashlib.sha256(original.encode()).hexdigest()[:12]+'-'+Path(original).name
                    shutil.copy2(original, destination/name); copied[original] = str(destination/name)
                m['path'] = copied[original]
        for t in plan['tracks']:
            for c in t['clips']:
                if c.get('media'):
                    c['media'] = copied[c['media']]
    plan['media_mode'] = 'copied' if copy_media else 'linked'
    atomic_json(job.output/'import-plan.json', plan)
    lines = ['# '+plan['name']+' — Ableton import', '',
             f"Source: `{source}`", '', f"{plan['stats']['tracks']} tracks, {plan['stats']['clips']} clip segments. Media is {plan['media_mode']}.",
             f"Missing/ambiguous sources: {plan['stats']['missing_media']}; affected arrangement clips: {plan['stats']['missing_arrangement_clips']}.", '',
             'The complete XML, every tag/attribute, and all vendor states are retained locally.',
             'See native-report.json after opening in REAPER for plug-in and automation results.', '', '## Review items', '']
    counts = collections.Counter((w['code'], w['message']) for w in plan['warnings'])
    lines += [f'- {code} ({count}): {message}' for (code, message), count in counts.items()]
    lines += ['', '## Missing media', '']+[f"- {m['status']}: `{m['original']}`" for m in plan['media'] if m['status'] != 'found']
    (job.output/'Import report.md').write_text('\n'.join(lines)+'\n')
    return plan


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source'); p.add_argument('--output', required=True)
    p.add_argument('--media-root', action='append', default=[])
    p.add_argument('--media-index'); p.add_argument('--copy-media', action='store_true')
    p.add_argument('--status')
    args = p.parse_args()
    try:
        index = json.loads(Path(args.media_index).read_text()) if args.media_index else None
        plan = prepare(args.source, args.output, args.media_root, index, args.copy_media)
        status = {'ok': True, 'plan': str(Path(args.output).resolve()/'import-plan.json'), 'stats': plan['stats']}
    except Exception as exc:
        status = {'ok': False, 'error': str(exc), 'traceback': traceback.format_exc()}
    if args.status:
        atomic_json(args.status, status)
    print(json.dumps(status))
    return 0 if status['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
