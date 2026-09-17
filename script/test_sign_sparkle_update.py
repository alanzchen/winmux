"""Headless credential selection and secret-safe signing subprocesses."""

import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('signing', Path(__file__).with_name('sign-sparkle-update.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class HeadlessSparkleTest(unittest.TestCase):
    def test_missing_file_fails_without_requesting_keychain_access(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(signing.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'No readable Sparkle key file'):
                signing.load_key({}, Path(directory) / 'missing')
            run.assert_not_called()

    def test_environment_supports_both_export_formats(self):
        for length in (32, 96):
            key = base64.b64encode(bytes(length)).decode()
            self.assertEqual(signing.load_key({'SPARKLE_PRIVATE_KEY': key}), key.encode())

    def test_environment_and_explicit_file_are_ambiguous(self):
        with self.assertRaisesRegex(ValueError, 'Set only'):
            signing.load_key({'SPARKLE_PRIVATE_KEY': 'private', 'SPARKLE_PRIVATE_KEY_FILE': '/missing'})

    def test_default_file_and_explicit_override(self):
        with tempfile.TemporaryDirectory() as directory:
            default = Path(directory) / 'default'
            explicit = Path(directory) / 'explicit'
            for path, byte in ((default, 1), (explicit, 2)):
                path.write_bytes(base64.b64encode(bytes([byte]) * 32))
                path.chmod(0o600)
            self.assertEqual(signing.load_key({}, default), default.read_bytes())
            self.assertEqual(signing.load_key({'SPARKLE_PRIVATE_KEY_FILE': str(explicit)}, default), explicit.read_bytes())

    def test_key_file_must_not_be_readable_by_other_users(self):
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / 'key'
            key_file.write_bytes(base64.b64encode(bytes(32)))
            key_file.chmod(0o644)
            with self.assertRaisesRegex(ValueError, 'permissions 600 or 400'):
                signing.load_key({}, key_file)

    def test_malformed_credentials_are_not_echoed(self):
        for key in ('sensitive-invalid-key!', base64.b64encode(b'sensitive-wrong-length').decode()):
            with self.assertRaises(ValueError) as caught:
                signing.load_key({'SPARKLE_PRIVATE_KEY': key})
            self.assertNotIn(key, str(caught.exception))

    def test_secret_is_sent_only_over_stdin(self):
        secret = base64.b64encode(bytes(32))
        arguments = ['sign_update', '--ed-key-file', '-', 'archive.zip']
        with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess(arguments, 0)) as run:
            signing.run_signer(arguments, secret, {'SPARKLE_PRIVATE_KEY': secret.decode(), 'PATH': '/usr/bin'})
        self.assertEqual(run.call_args.args[0], arguments)
        self.assertEqual(run.call_args.kwargs['input'], secret + b'\n')
        self.assertEqual(run.call_args.kwargs['env'], {'PATH': '/usr/bin'})
        self.assertEqual(run.call_args.kwargs['stdout'], subprocess.PIPE)
        self.assertEqual(run.call_args.kwargs['stderr'], subprocess.PIPE)

    def test_signer_errors_do_not_expose_output(self):
        with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'secret', b'secret')):
            with self.assertRaises(ValueError) as caught:
                signing.run_signer(['generate_appcast'], b'secret', {})
            self.assertNotIn('secret', str(caught.exception))
