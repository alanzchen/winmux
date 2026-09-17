"""A locked signing Keychain must fail without requesting an unlock."""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('keychain', Path(__file__).with_name('check-signing-keychain.py'))
keychain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keychain)


class SigningKeychainTest(unittest.TestCase):
    def library(self, flags):
        security = MagicMock()
        security.SecKeychainOpen.return_value = 0
        security.SecKeychainCopyDefault.return_value = 0

        def read_status(_, output):
            output._obj.value = flags
            return 0

        security.SecKeychainGetStatus.side_effect = read_status
        return security

    def test_locked_keychain_fails_without_unlocking(self):
        security = self.library(0)
        foundation = MagicMock()
        with patch.object(keychain.ctypes, 'CDLL', side_effect=[security, foundation]):
            with self.assertRaisesRegex(ValueError, 'Keychain is locked'):
                keychain.check_unlocked('/signing.keychain-db')
        security.SecKeychainUnlock.assert_not_called()
        foundation.CFRelease.assert_called_once()

    def test_unlocked_default_keychain_passes(self):
        security = self.library(1)
        with patch.object(keychain.ctypes, 'CDLL', side_effect=[security, MagicMock()]):
            keychain.check_unlocked('')
        security.SecKeychainCopyDefault.assert_called_once()
        security.SecKeychainOpen.assert_not_called()
        security.SecKeychainUnlock.assert_not_called()

    def test_unavailable_keychain_fails_before_signing(self):
        security = self.library(1)
        security.SecKeychainOpen.return_value = -25294
        with patch.object(keychain.ctypes, 'CDLL', side_effect=[security, MagicMock()]):
            with self.assertRaisesRegex(ValueError, 'Keychain is unavailable'):
                keychain.check_unlocked('/missing.keychain-db')
        security.SecKeychainGetStatus.assert_not_called()
        security.SecKeychainUnlock.assert_not_called()
