"""Read-only Ableton Live XML inventory and semantic model for Solo Studio.

No Live set or referenced source file is ever modified. XML and vendor state are
private import artifacts, not source-code fixtures. Python standard library only.
"""
from __future__ import annotations
import argparse
import collections
import gzip
import hashlib
import json
import math
import re
from pathlib import Path
import xml.etree.ElementTree as ET

MAX_XML = 128 * 1024 * 1024


def value(node, path, default=None):
    child = node.find(path) if node is not None else None
    return child.get('Value', default) if child is not None else default


def number(node, path, default=0.0):
    v = float(value(node, path, default))
    if not math.isfinite(v):
        raise ValueError(f'Non-finite number in {path}')
    return v


def boolean(node, path, default=False):
    return value(node, path, str(default).lower()) == 'true'


def read_set(path):
    path = Path(path).expanduser().resolve()
    with path.open('rb') as f:
        compressed = f.read(2) == b'\x1f\x8b'
    with (gzip.open(path, 'rb') if compressed else path.open('rb')) as f:
        data = f.read(MAX_XML + 1)
    if len(data) > MAX_XML:
        raise ValueError('Live Set exceeds the 128 MiB XML limit')
    if b'<!ENTITY' in data or b'<!DOCTYPE' in data:
        raise ValueError('External XML declarations are not accepted')
    root = ET.fromstring(data)
    if root.tag != 'Ableton' or root.find('LiveSet') is None:
        raise ValueError('Not an Ableton Live Set')
    return path, root, data


def walk(node, path=''):
    """Every element, with both a stable tag path and an unambiguous occurrence path."""
    def visit(n, tags, address):
        yield n, tags, address
        counts = collections.Counter()
        for child in n:
            counts[child.tag] += 1
            yield from visit(child, tags + '/' + child.tag,
                             address + '/' + child.tag + f'[{counts[child.tag]}]')
    yield from visit(node, path + '/' + node.tag, path + '/' + node.tag + '[1]')


def category(path):
    if any(t in path for t in ('PluginDesc', 'ProcessorState', 'ControllerState')):
        return 'plugin identity and opaque vendor state'
    if any(t in path for t in ('Automation', 'Modulation', 'Envelope', 'MacroControl', 'MidiControllerRange')):
        return 'automation, modulation and control mapping'
    if any(t in path for t in ('Routing', '/Sends', '/Mixer', '/TrackGroup', '/LinkedTrack', '/TrackDelay')):
        return 'mixer and routing'
    if any(t in path for t in ('AudioClip', 'MidiClip', 'SampleRef', 'TakeLane', 'Warp', 'ClipSlot', '/Scenes')):
        return 'clips, takes, MIDI and media'
    if '/Devices/' in path or '/Branches/' in path:
        return 'device or rack settings'
    if any(t in path for t in ('Tempo', 'TimeSignature', '/Transport', '/Locators', '/Groove', '/Tuning')):
        return 'song timing and structure'
    if any(t in path for t in ('View', 'LomId', 'Scroller', 'Selected', 'IsExpanded', 'IsFolded', 'Grid', 'Navigator', 'Window')):
        return 'editor layout and selection (archive only)'
    return 'project metadata or setting requiring review'


def plugin_description(device):
    desc = device.find('PluginDesc')
    if desc is None or not len(desc):
        return None
    info = desc[0]
    preset = info.find('Preset')
    preset = preset[0] if preset is not None and len(preset) else None
    result = {'kind': info.tag, 'name': value(info, 'Name', value(preset, 'PluginName', '')),
              'manufacturer': value(info, 'Manufacturer', ''), 'device_id': device.get('Id'),
              'enabled': boolean(device, 'On/Manual', True)}
    if info.tag == 'Vst3PluginInfo':
        result['name'] = result['name'] or value(preset, 'Name', '')
        result['uid'] = ''.join(f'{int(value(preset, "Uid/Fields."+str(i), 0)) & 0xffffffff:08X}' for i in range(4))
    elif info.tag == 'VstPluginInfo':
        result['unique_id'] = value(preset, 'UniqueId', value(info, 'UniqueId', ''))
        result['name'] = value(info, 'PlugName', result['name'])
    elif info.tag == 'AuPluginInfo':
        result['component'] = {k: value(info, 'Component' + k) for k in ('Type', 'SubType', 'Manufacturer')}
    result['state'] = {}
    if preset is not None:
        for tag in ('Buffer', 'ProcessorState', 'ControllerState'):
            text = preset.findtext(tag)
            if text:
                blob = bytes.fromhex(''.join(text.split()))
                result['state'][tag] = {'bytes': len(blob), 'sha256': hashlib.sha256(blob).hexdigest()}
    return result


def summarize(path, root):
    ls = root.find('LiveSet'); tracks = []
    for t in list(ls.find('Tracks')) + [ls.find('MainTrack') or ls.find('MasterTrack')]:
        if t is None:
            continue
        seq = t.find('DeviceChain/MainSequencer')
        arrangement = []
        if seq is not None:
            for event_path in ('Sample/ArrangerAutomation/Events', 'ClipTimeable/ArrangerAutomation/Events'):
                parent = seq.find(event_path)
                if parent is not None:
                    arrangement.extend(e for e in parent if e.tag in ('AudioClip', 'MidiClip'))
        lanes = t.findall('TakeLanes/TakeLanes/TakeLane')
        clips = t.findall('.//AudioClip') + t.findall('.//MidiClip')
        devices = [d for d in t.findall('.//Devices/*') if d.tag not in ('Mixer',)]
        tracks.append({'id': t.get('Id', t.tag), 'type': t.tag,
                       'name': value(t, 'Name/EffectiveName', t.tag),
                       'group': value(t, 'TrackGroupId', '-1'),
                       'audio_input': value(t, 'DeviceChain/AudioInputRouting/Target', ''),
                       'audio_output': value(t, 'DeviceChain/AudioOutputRouting/Target', ''),
                       'arrangement_clips': len(arrangement), 'total_clips': len(clips),
                       'take_lanes': len(lanes),
                       'automation_envelopes': len(t.findall('.//AutomationEnvelope')),
                       'devices': [{'type': d.tag, 'name': value(d, 'UserName', ''),
                                    'plugin': plugin_description(d)} for d in devices]})
    refs = {}
    for ref in ls.findall('.//SampleRef/FileRef'):
        original = value(ref, 'Path', '')
        relative = value(ref, 'RelativePath', '')
        candidates = [Path(original), path.parent / relative]
        refs[(original, relative)] = {'path': original, 'relative': relative,
                                      'exists_at_stored_path': (None if any('/Mobile Documents/' in str(p) or '/CloudStorage/' in str(p) for p in candidates) else any(p.is_file() for p in candidates)),
                                      'expected_bytes': int(value(ref, 'OriginalFileSize', 0))}
    main = ls.find('MainTrack') or ls.find('MasterTrack')
    return {'source': str(path), 'creator': root.get('Creator'), 'schema': root.attrib,
            'bpm': number(main, 'DeviceChain/Mixer/Tempo/Manual', 120), 'tracks': tracks,
            'media': list(refs.values()),
            'tags': dict(collections.Counter(e.tag for e in root.iter())),
            'devices': dict(collections.Counter(d['type'] for t in tracks for d in t['devices']))}


def inventory(source, output):
    path, root, xml = read_set(source)
    output = Path(output); output.mkdir(parents=True, exist_ok=True)
    report = summarize(path, root)
    report['xml_sha256'] = hashlib.sha256(xml).hexdigest()
    report['source_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['xml_bytes'] = len(xml)
    (output / 'source.xml.gz').write_bytes(gzip.compress(xml))
    catalog = {}
    with gzip.open(output / 'nodes.jsonl.gz', 'wt', encoding='utf-8') as stream:
        for element, tag_path, address in walk(root):
            text = (element.text or '').strip()
            # Full values, including state, are preserved in this private node index.
            stream.write(json.dumps({'path': address, 'tag_path': tag_path,
                                     'attributes': element.attrib, 'text': text}, ensure_ascii=False) + '\n')
            row = catalog.setdefault(tag_path, {'count': 0, 'category': category(tag_path),
                                               'attributes': {}, 'text_count': 0})
            row['count'] += 1
            row['text_count'] += bool(text)
            for key, val in element.attrib.items():
                a = row['attributes'].setdefault(key, {'count': 0, 'values': collections.Counter()})
                a['count'] += 1; a['values'][val] += 1
    report['node_count'] = sum(row['count'] for row in catalog.values())
    report['tag_paths'] = len(catalog)
    for name, data in [('catalog.json', catalog), ('summary.json', report)]:
        (output / name).write_text(json.dumps(data, indent=2, ensure_ascii=False))
    text = [f'# {path.stem}', '', f'Source: `{path}`', '',
            f'{report["node_count"]:,} XML elements; {len(report["tags"]):,} distinct tags; '
            f'{len(catalog):,} complete tag paths. All attributes and text are indexed.', '',
            '| Track | Type | Group | Arrangement clips | All clips | Take lanes | Devices |',
            '| --- | --- | --- | ---: | ---: | ---: | --- |']
    for t in report['tracks']:
        names = [d['plugin']['name'] if d['plugin'] else d['type'] for d in t['devices']]
        text.append(f'| {t["name"].replace("|", "/")} | {t["type"]} | {t["group"]} | '
                    f'{t["arrangement_clips"]} | {t["total_clips"]} | {t["take_lanes"]} | {", ".join(names)} |')
    missing = [m for m in report['media'] if m['exists_at_stored_path'] is False]
    text += ['', f'Media references: {len(report["media"])}; absent at their stored paths: {len(missing)}.',
             'Cloud-provider paths are indexed without synchronous existence checks. Media relinking is a separate pass; an absent stored path does not prove the recording is lost.', '',
             'Private artifacts: `source.xml.gz` retains the complete XML; `nodes.jsonl.gz` indexes every',
             'element occurrence and value; `catalog.json` catalogs every tag path and attribute value.',
             'This is an inventory, not a claim that every setting has a REAPER equivalent.']
    (output / 'README.md').write_text('\n'.join(text) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', nargs='+')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    index = []
    for source in args.source:
        path = Path(source)
        key = re.sub(r'[^\w .-]', '_', path.stem)[:90] + '-' + hashlib.sha256(str(path).encode()).hexdigest()[:8]
        try:
            report = inventory(path, Path(args.output) / key)
            index.append({'source': str(path), 'folder': key, 'nodes': report['node_count'],
                          'tags': len(report['tags']), 'tracks': len(report['tracks'])})
            print(path.name, report['node_count'], 'elements', flush=True)
        except Exception as exc:
            index.append({'source': str(path), 'error': str(exc)})
            print(path.name, 'ERROR', exc, flush=True)
    Path(args.output, 'index.json').write_text(json.dumps(index, indent=2))


if __name__ == '__main__':
    main()
