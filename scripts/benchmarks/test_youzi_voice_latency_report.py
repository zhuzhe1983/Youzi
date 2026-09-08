"""Offline evidence/report gates; no models, network, audio devices, or credentials."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('report', Path(__file__).with_name('youzi_voice_latency_report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def fixture():
    times = [('llm_request', 0), ('first_text', .2), ('sentence_ready', .4),
             ('tts_request', .4), ('first_pcm_byte', 1), ('tts_eof', 1.01),
             ('pcm_enqueued', 1.02), ('first_nonsilent_render', 1.2),
             ('llm_done', 2), ('playback_drained', 3)]
    return {'status': 'completed', 'sentence_count': 1, 'tts_transport_mode': 'buffered_legacy',
            'events': [{'event': n, 'seconds': t, 'segment': 1, 'observed_seconds': t} for n, t in times]}


class ReportTests(unittest.TestCase):
    def test_valid_observed_sequence(self):
        report.validate_run(fixture())

    def test_rejects_stale_previous_sentence_tap(self):
        run = fixture()
        next(e for e in run['events'] if e['event'] == 'first_nonsilent_render')['seconds'] = .8
        with self.assertRaisesRegex(ValueError, 'tap ordering'):
            report.validate_run(run)

    def test_missing_render_cannot_be_reported_as_completed(self):
        run = fixture()
        run['events'] = [e for e in run['events'] if e['event'] != 'first_nonsilent_render']
        with self.assertRaisesRegex(ValueError, 'Missing'):
            report.validate_run(run)

    def test_rejects_buffered_label_on_partial_receipt(self):
        run = fixture()
        next(e for e in run['events'] if e['event'] == 'tts_eof')['seconds'] = 1.1
        with self.assertRaisesRegex(ValueError, 'receive all PCM'):
            report.validate_run(run)

    def test_report_requires_real_result_files(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, 'No actual'):
                report.make_report(Path(folder))

    def test_payload_cannot_close_script_element(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder); run_dir = path / 'run-1'; run_dir.mkdir()
            run = fixture(); run['llm_text'] = '</script><script>alert(1)</script>'
            (run_dir / 'results.json').write_text(json.dumps(run))
            (run_dir / 'sentence-1.pcm').write_bytes(b'\x00\x00' * 240)
            text = report.make_report(path).read_text()
            self.assertNotIn(run['llm_text'], text)
            self.assertIn('\\u003c/script\\u003e', text)
            self.assertIn('data:audio/wav;base64,', text)
            self.assertTrue((run_dir / 'reply.wav').is_file())

    def test_failed_attempt_kept_but_not_promoted(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder); run_dir = path / 'run-1'; run_dir.mkdir()
            (run_dir / 'results.json').write_text(json.dumps({'status': 'failed', 'events': [], 'error': 'muted'}))
            (run_dir / 'sentence-1.pcm').write_bytes(b'\x00\x00' * 240)
            data = report.collect(path)
            self.assertEqual(data['runs'][0]['status'], 'failed')
            self.assertNotIn('audio_data_uri', data['runs'][0])


if __name__ == '__main__':
    unittest.main()
