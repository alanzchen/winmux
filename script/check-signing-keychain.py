#!/usr/bin/env python3
"""Fail before signing if the selected Keychain is locked; never unlock it via UI."""

import ctypes
import os
import sys


def check_unlocked(path):
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    keychain = ctypes.c_void_p()
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainCopyDefault.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainGetStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    foundation.CFRelease.restype = None
    status = (security.SecKeychainOpen(os.fsencode(path), ctypes.byref(keychain)) if path
              else security.SecKeychainCopyDefault(ctypes.byref(keychain)))
    if status != 0:
        raise ValueError('The signing Keychain is unavailable; configure it before running a headless release.')
    try:
        flags = ctypes.c_uint32()
        status = security.SecKeychainGetStatus(keychain, ctypes.byref(flags))
        if status != 0 or not flags.value & 1:  # kSecUnlockStateStatus
            raise ValueError('The signing Keychain is locked. Unlock it before running the release; no interactive unlock will be requested.')
    finally:
        foundation.CFRelease(keychain)


if __name__ == '__main__':
    try:
        check_unlocked(os.environ.get('NOTARYTOOL_KEYCHAIN', ''))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
