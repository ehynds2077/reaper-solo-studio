# Recording workflow checks

The standalone interaction checks need Lua 5.3 or newer. From the repository root:

```sh
lua 'Tests/Visual timeline interactions.lua'
lua 'Tests/Panel tempo interactions.lua'
lua 'Tests/Section stop helper.lua'
lua 'Tests/Lead-in restoration.lua'
```

For the native REAPER checks, first generate their synthetic audio:

```sh
python3 Tests/make_fixtures.py
```

Install the production scripts as described in the main README. Stop transport,
then load the desired `Run ... checks.lua` script from REAPER's Actions list.
The integration, tempo, section, and lead-in checks use separate test projects;
the visual section check opens its own interactive fixture. Test projects, audio,
and logs are generated locally and excluded from Git.

`Run lead-in checks.lua` requires an available audio device and native pre-roll
set to two measures. It records silent track outputs with muted hardware sends,
meters a generated guide tone, and checks punch-in, looping, and early stopping.
It restores the original project and verifies its track count, media count,
tempo, region count, and record arming.

The tuner has its own [DSP validation workbench](../Tuner/Tests/README.md).
