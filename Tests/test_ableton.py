"""Synthetic ALS fixtures: no recordings or proprietary plugin states in Git."""
import gzip
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Ableton'))
from als import inventory, read_set
from prepare import Tempo, Media, Import, events, segments, signature, warp_seconds, prepare


class AbletonTests(unittest.TestCase):
    def test_archive_is_exhaustive(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'song.als'
            xml = b'<Ableton Creator="test"><LiveSet><Tracks/><MainTrack><Name><EffectiveName Value="Main"/></Name></MainTrack><Unknown Value="a"><Blob>001122</Blob></Unknown></LiveSet></Ableton>'
            p.write_bytes(gzip.compress(xml)); before=p.read_bytes()
            result=inventory(p,Path(tmp)/'audit')
            nodes=[json.loads(x) for x in gzip.open(Path(tmp)/'audit/nodes.jsonl.gz','rt')]
            self.assertEqual(result['node_count'],len(list(ET.fromstring(xml).iter())))
            self.assertEqual(nodes[-1]['text'],'001122')
            self.assertEqual(gzip.open(Path(tmp)/'audit/source.xml.gz').read(),xml)
            self.assertEqual(p.read_bytes(),before)

    def test_unsafe_xml_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'bad.als';p.write_text('<!DOCTYPE Ableton [<!ENTITY x SYSTEM "file:///etc/passwd">]><Ableton><LiveSet/></Ableton>')
            with self.assertRaises(ValueError):read_set(p)

    def test_tempo_ramp_integral_and_markers(self):
        t=Tempo(120,[{'beat':0,'value':120},{'beat':16,'value':180}])
        expected=60/(60/16)*math.log(1.5)
        self.assertAlmostEqual(t.seconds(16),expected)
        markers=t.markers()
        elapsed=sum((b['time']-a['time'])*a['bpm']/60 for a,b in zip(markers,markers[1:]))
        self.assertAlmostEqual(elapsed,16)
        self.assertEqual(signature(201),(4,4))
        self.assertEqual(signature(303),(7,8))

    def test_loops_and_warp_trim(self):
        self.assertEqual(list(segments(10,20,3,2,6,True)),[(10,13,3),(13,17,2),(17,20,2)])
        self.assertAlmostEqual(warp_seconds([[0,0],[4,2],[8,5]],6,120),3.5)
        self.assertAlmostEqual(warp_seconds([[0,0],[4,2]],-1,120),-.5)

    def test_initial_value_is_held_before_first_real_breakpoint(self):
        env=ET.fromstring('<Envelope><Automation><Events><FloatEvent Time="-63072000" Value="133"/><FloatEvent Time="2880" Value="124"/></Events></Automation></Envelope>')
        t=Tempo(120,events(env))
        self.assertAlmostEqual(t.seconds(2880),2880*60/133)
        self.assertEqual(len(t.markers()),2)

    def test_stale_send_ids_use_ordered_returns(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'routing.als'
            p.write_text('''<Ableton><LiveSet><SendsPre><SendPreBool Id="0" Value="false"/><SendPreBool Id="3" Value="true"/></SendsPre><Tracks>
            <AudioTrack Id="1"><DeviceChain><Mixer><Sends><TrackSendHolder Id="0"><Send><Manual Value="0.2"/></Send></TrackSendHolder><TrackSendHolder Id="1"><Send><Manual Value="0.4"/></Send></TrackSendHolder></Sends></Mixer></DeviceChain></AudioTrack>
            <ReturnTrack Id="20"><DeviceChain><Mixer/></DeviceChain></ReturnTrack><ReturnTrack Id="30"><DeviceChain><Mixer/></DeviceChain></ReturnTrack>
            </Tracks><MainTrack><DeviceChain><Mixer/></DeviceChain></MainTrack></LiveSet></Ableton>''')
            plan=Import(p,root/'out').build();sends=plan['tracks'][0]['sends']
            self.assertEqual([s['destination']for s in sends],['20','30'])
            self.assertTrue(sends[1]['pre'])

    def test_unwarped_pitch_loops_and_fades(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'simple.als';p.write_text('<Ableton><LiveSet><Tracks/><MainTrack><DeviceChain><Mixer/></DeviceChain></MainTrack></LiveSet></Ableton>')
            job=Import(p,root/'out')
            clip=ET.fromstring('''<AudioClip><CurrentStart Value="0"/><CurrentEnd Value="8"/><PitchCoarse Value="12"/>
             <Loop><LoopStart Value="0"/><LoopEnd Value="4"/><LoopOn Value="true"/></Loop>
             <Fades><FadeInLength Value="0.1"/><FadeOutLength Value="0.2"/></Fades></AudioClip>''')
            rows=list(job.clip(clip,0,'arrangement',{}))
            self.assertEqual([(c['position'],c['length'])for c in rows],[(0,2),(2,2)])
            self.assertAlmostEqual(rows[0]['fade_in'],.05)
            self.assertEqual(rows[0]['fade_out'],0)
            self.assertEqual(rows[1]['fade_in'],0)
            self.assertAlmostEqual(rows[1]['fade_out'],.1)

    def test_relink_does_not_choose_conflicting_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'a').mkdir();(root/'b').mkdir()
            (root/'a/take.wav').write_bytes(b'123');(root/'b/take.wav').write_bytes(b'456')
            c=ET.fromstring('<AudioClip><SampleRef><FileRef><Path Value="/missing/take.wav"/><OriginalFileSize Value="3"/></FileRef></SampleRef></AudioClip>')
            m=Media(root/'song.als');self.assertEqual(m.resolve(c)['status'],'ambiguous')
            (root/'b/take.wav').write_bytes(b'123')
            self.assertEqual(Media(root/'song.als').resolve(c)['status'],'found')

    def test_audio_and_midi_timeline_and_automation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'fixture.als'
            xml='''<Ableton Creator="fixture"><LiveSet><Tracks>
            <AudioTrack Id="1"><Name><EffectiveName Value="Guitar"/></Name><TrackGroupId Value="-1"/>
             <DeviceChain><Mixer><Volume><Manual Value="0.5"/><AutomationTarget Id="10"/></Volume></Mixer>
             <MainSequencer><Sample><ArrangerAutomation><Events><AudioClip Id="0" Time="8">
              <CurrentStart Value="8"/><CurrentEnd Value="16"/><Name Value="trim"/>
              <Loop><LoopStart Value="4"/><LoopEnd Value="100"/><LoopOn Value="false"/></Loop>
              <IsWarped Value="true"/><WarpMarkers><WarpMarker BeatTime="0" SecTime="0"/><WarpMarker BeatTime="8" SecTime="4"/></WarpMarkers>
              <SampleRef><FileRef><Path Value="/missing.wav"/></FileRef></SampleRef>
             </AudioClip></Events></ArrangerAutomation></Sample></MainSequencer><DeviceChain><Devices/></DeviceChain></DeviceChain>
             <AutomationEnvelopes><Envelopes><AutomationEnvelope><EnvelopeTarget><PointeeId Value="10"/></EnvelopeTarget><Automation><Events><FloatEvent Time="-63072000" Value="0.5"/><FloatEvent Time="8" Value="1"/></Events></Automation></AutomationEnvelope></Envelopes></AutomationEnvelopes>
            </AudioTrack></Tracks><MainTrack><DeviceChain><Mixer><Tempo><Manual Value="120"/></Tempo></Mixer></DeviceChain></MainTrack></LiveSet></Ableton>'''
            p.write_bytes(gzip.compress(xml.encode()));plan=prepare(p,root/'import')
            clip=plan['tracks'][0]['clips'][0]
            self.assertEqual((clip['position'],clip['length'],clip['offset']),(4,4,2))
            self.assertEqual(clip['stretch'],[[0,2],[2,4],[4,6]])
            self.assertEqual(plan['automation'][0]['kind'],'volume')
            self.assertEqual(plan['automation'][0]['points'][1]['time'],4)
            self.assertEqual(plan['stats']['missing_arrangement_clips'],1)
            with self.assertRaises(FileExistsError):prepare(p,root/'import')


if __name__=='__main__':unittest.main()
