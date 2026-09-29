# Ableton Live imports

In **Projects → Import Ableton…**, choose an `.als` file. Optionally provide a
folder containing moved recordings. Analysis runs locally in Python 3; when it
finishes, **Report** opens its folder and **Open imported song** builds a separate
REAPER project. Stop transport before opening the import. Source sets and audio
are never changed. The previous REAPER song remains open.

Imports live under `~/Desktop/Solo Studio Songs/`. Audio stays linked to its
existing location by default. The CLI's `--copy-media` option creates a separate
copy of every resolved referenced recording, including unused takes. Missing
media produces named placeholders at the original positions. Reimport with a
relink folder once recordings are recovered; the original import remains intact.
Conflicting same-name recordings are never selected arbitrarily.

## Transferred and preserved

| Feature | Handling |
| --- | --- |
| Arrangement audio | Positions, trims, source offsets, gain, pitch, mute, loop iterations and fade lengths |
| Warped audio | Warp-marker timing becomes native stretch markers; Live's stretching algorithms are not reproduced |
| Take lanes | Preserved as inactive fixed lanes; arrangement becomes the playing Comp lane |
| Session clips | Preserved in separate inactive lanes; Session launching/follow actions remain archived |
| MIDI | Notes, velocities, note mute, pitch bend, pressure and CC breakpoints including sustain |
| Tracks and groups | Original order, nested folders, explicit group/master routes, volumes, pans and mute/solo |
| Returns | Ordered return destinations, enabled state, pre/post mode and send level automation |
| Audio inputs/outputs | Numbered inputs; hardware outputs where available; record arming and monitoring off |
| AU plug-ins | Original component type/subtype/manufacturer checked; complete Apple preset restored through the native AU state container |
| VST3 plug-ins | Original class UID checked after instantiation; processor/controller state loaded as a `.vstpreset` |
| FabFilter/UAD/other vendors | Same-format state transfer; no AU↔VST conversion or similarly named substitute |
| Automation | Mixer and supported plug-in parameters resolved by target/parameter IDs; enum values normalized; breakpoints transferred |
| Tempo/meter | Time map and meter markers; beat-domain tempo ramps subdivided at 1/16 beat |
| Song sections | Locators become section regions, ending at the next locator or arrangement end |
| Linked tracks | Recording-set membership and native media-edit grouping |
| Single-chain audio racks | Unity-gain chains expanded in order, including rack bypass automation |
| Other XML/settings | Every element, attribute, value and opaque vendor-state byte archived locally |

This is an editable migration, **not a guaranteed identical-sounding conversion**.
Inspect both reports before using an import as a replacement for its Live set.

Live-native EQ Eight, Reverb, Delay, Glue Compressor, Max devices and other
unsupported devices remain labeled, bypassed placeholders. VST2 state is archived
but its native loader is not yet validated. Parallel/non-unity racks, macro and
modulation mappings, audio clip modulation, external sidechains, MPE/note-expression,
grooves, follow actions, MIDI probability and custom automation/fade curves need
review or committed audio from Live. Freeze data is archived; editable source
tracks are imported. Editor layouts and Live color indices remain in the archive.
Different warp engines can change transients even when timing agrees.

An unusual initial tempo envelope whose pre-roll value differs from the first
real breakpoint is explicitly flagged for comparison with Live. The importer
holds that initial value until the first breakpoint. It does not infer the
historical recording BPM of an old take from the current song tempo.

## Complete XML inventory

Each import contains:

- `XML inventory/source.xml.gz`: unchanged decompressed source XML, compressed again.
- `XML inventory/nodes.jsonl.gz`: every element occurrence, unambiguous path,
  every attribute and complete text, including binary-state hex.
- `XML inventory/catalog.json`: every tag path, occurrence count, category,
  attribute and all distinct attribute values/counts.
- `XML inventory/summary.json`: version, tracks, routing, device inventory,
  media references and source/XML SHA-256 hashes.
- `Plugin states/`: individual native vendor state files.
- `import-plan.json`: explicit conversion model, media resolution and warnings.
- `Import report.md`: human-readable analysis and missing-media list.
- `native-report.json`: actual REAPER results, plug-in state acceptance, exposed
  parameter comparisons, automation results and verification that the original
  project revision was unchanged.

These artifacts can contain personal paths, recordings and proprietary plug-in
data. They stay local and are excluded from this repository.

```sh
python3 Ableton/als.py '/path/song.als' --output '/path/private-audit'
python3 Ableton/prepare.py '/path/song.als' --output '/path/new-import-folder' \
  --media-root '/path/recovered-recordings' --copy-media
```

The destination for `prepare.py` must not exist. No third-party Python packages
are needed. `.als` gzip and uncompressed XML are supported; compressed XML is
bounded at 128 MiB and entity/DTD declarations are rejected.

## Installation and validation

Copy `Ableton/*.py` into `Scripts/Solo Studio/Ableton/` inside REAPER's resource
folder, alongside the installed Lua scripts. The project view loads
`solo_ableton.lua` as needed. macOS's `/usr/bin/python3` is used by the panel.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_ableton.py -v
python3 Tests/make_ableton_fixture.py '/path/to/your/set-with-AU-and-VST3.als'
```

Run `Tests/Run Ableton import checks.lua` from REAPER's Actions list using **Run**.
It checks an isolated fixture with synthetic audio, copied local plug-in states,
no hardware output, groups/sends, automation, MIDI sustain, trims/warp markers,
inactive takes, saved projects and preservation of the original project.
Fixtures and results stay under `/private/tmp/Tests/solo-ableton-native-plan`.

Native state loading follows the [REAPER ReaScript API](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
and [Steinberg VST3 preset specification](https://steinbergmedia.github.io/vst3_dev_portal/pages/Technical%2BDocumentation/Locations%2BFormat/Preset%2BFormat.html).
The Live XML interpretation is based on local set inspection and synthetic/native
checks; Ableton's project format is not a stable public interchange contract.
