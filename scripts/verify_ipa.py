#!/usr/bin/env python3
"""Inspect an actual IPA's device Mach-O and bundle metadata without extracting it.

This is structural validation. Apple signature trust and provisioning authorization
must also be checked by codesign and the target device; build_ipa.sh does the Mac check.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import stat
import struct
import sys
import zipfile


class InvalidIPA(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidIPA(message)


def version_number(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def version_tuple(value: str) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in value.split('.'))
    except (ValueError, AttributeError) as error:
        raise InvalidIPA(f"Invalid version: {value!r}") from error


def macho_images(data: bytes) -> list[dict]:
    require(len(data) >= 32, 'The executable is too small to be a Mach-O binary.')
    # Fat containers use big-endian headers; each arm64 slice is checked independently.
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        fat64 = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        require(0 < count <= 8, 'Unexpected Mach-O architecture count.')
        stride = 32 if fat64 else 20
        require(8 + count * stride <= len(data), 'Truncated universal Mach-O header.')
        result = []
        for index in range(count):
            start = 8 + index * stride
            if fat64:
                cpu, subtype, offset, size, _, _ = struct.unpack_from('>IIQQII', data, start)
            else:
                cpu, subtype, offset, size, _ = struct.unpack_from('>IIIII', data, start)
            require(cpu == 0x0100000C, 'IPA contains a non-arm64 architecture.')
            require(offset >= 8 + count * stride and size > 0 and offset + size <= len(data), 'Invalid Mach-O slice bounds.')
            result.extend(macho_images(data[offset:offset + size]))
        return result
    require(data[:4] == b'\xcf\xfa\xed\xfe', 'The executable is not a compiled 64-bit Apple Mach-O binary.')
    _, cpu, subtype, filetype, count, commands_size, _, _ = struct.unpack_from('<IIIIIIII', data)
    require(cpu == 0x0100000C, 'The app executable is not arm64 device code.')
    require(filetype == 2, 'The app binary is not an MH_EXECUTE executable.')
    require(0 < count <= 4096 and 32 + commands_size <= len(data), 'Truncated Mach-O load commands.')
    cursor = 32
    build_versions, dylibs = [], []
    has_signature = False
    for _ in range(count):
        require(cursor + 8 <= 32 + commands_size, 'Truncated Mach-O command header.')
        command, size = struct.unpack_from('<II', data, cursor)
        require(size >= 8 and cursor + size <= 32 + commands_size, 'Invalid Mach-O load command size.')
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, 'Truncated LC_BUILD_VERSION.')
            platform, minimum, sdk, _ = struct.unpack_from('<IIII', data, cursor + 8)
            build_versions.append({'platform': platform, 'minimumOS': version_number(minimum), 'sdk': version_number(sdk)})
        elif command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            require(size >= 24, 'Truncated dylib command.')
            name_offset = struct.unpack_from('<I', data, cursor + 8)[0]
            require(24 <= name_offset < size, 'Invalid dylib name offset.')
            name = data[cursor + name_offset:cursor + size].split(b'\0', 1)[0].decode('utf-8')
            dylibs.append(name)
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            require(size >= 16, 'Truncated code-signature command.')
            offset, signature_size = struct.unpack_from('<II', data, cursor + 8)
            require(signature_size > 0 and offset + signature_size <= len(data), 'Invalid Mach-O signature bounds.')
            has_signature = True
        cursor += size
    require(cursor == 32 + commands_size, 'Mach-O load command count does not match its size.')
    require(len(build_versions) == 1 and build_versions[0]['platform'] == 2, 'The binary must target iOS devices (platform IOS=2), not an iOS simulator or macOS.')
    build = build_versions[0]
    require(version_tuple(build['sdk']) >= (26, 0), 'The executable was not linked against iOS SDK 26 or newer.')
    require(version_tuple(build['minimumOS']) >= (17, 0), 'The app deployment target is below its supported iOS 17 baseline.')
    require(any(name.endswith('/SwiftUI.framework/SwiftUI') for name in dylibs), 'No SwiftUI framework load command was found.')
    return [{'architecture': 'arm64e' if subtype & 0xFFFFFF == 2 else 'arm64', **build, 'swiftUILinked': True, 'codeSignatureCommand': has_signature}]


def inspect_archive(archive: zipfile.ZipFile, expected_signing: str) -> dict:
    entries = archive.infolist()
    require(0 < len(entries) <= 20000, 'Unexpected IPA entry count.')
    require(sum(entry.file_size for entry in entries) <= 2 * 1024**3, 'IPA uncompressed size exceeds the verification limit.')
    names = [entry.filename for entry in entries]
    require(len(names) == len(set(names)), 'IPA has duplicate archive paths.')
    for name in names:
        path = PurePosixPath(name)
        require('\\' not in name and not path.is_absolute() and '..' not in path.parts, 'IPA has an unsafe archive path.')
    apps = {PurePosixPath(name).parts[1] for name in names if len(PurePosixPath(name).parts) >= 3 and PurePosixPath(name).parts[0] == 'Payload' and PurePosixPath(name).parts[1].endswith('.app')}
    require(len(apps) == 1, 'IPA must contain exactly one app directly inside Payload/.')
    root = 'Payload/' + next(iter(apps)) + '/'
    require(root + 'Info.plist' in names, 'The app has no Info.plist.')
    info = plistlib.loads(archive.read(root + 'Info.plist'))
    require(info.get('CFBundlePackageType') == 'APPL', 'The bundle is not an iOS application.')
    require(sorted(info.get('UIDeviceFamily', [])) == [1, 2], 'The app must support both iPhone (1) and iPad (2).')
    require(not info.get('UIRequiresFullScreen', False), 'The iPad app must not require a full-screen-only window.')
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'The app bundle is not built for iOS devices.')
    sdk_name = info.get('DTSDKName', '')
    require(sdk_name.startswith('iphoneos') and version_tuple(sdk_name[len('iphoneos'):]) >= (26, 0), 'Info.plist does not declare iOS SDK 26+.')
    require(version_tuple(info.get('MinimumOSVersion', '0')) >= (17, 0), 'Info.plist has an unsupported deployment target.')
    require(not info.get('UIDesignRequiresCompatibility', False), 'The app opts out of Liquid Glass through UIDesignRequiresCompatibility.')
    executable = info.get('CFBundleExecutable', '')
    require(bool(executable) and '/' not in executable and '\\' not in executable and executable not in ('.', '..'), 'Invalid app executable path.')
    executable_path = root + executable
    require(executable_path in names, 'The compiled app executable is missing.')
    metadata = archive.getinfo(executable_path)
    require(bool((metadata.external_attr >> 16) & 0o111), 'The app executable has lost its executable file permission in the IPA.')
    binary = archive.read(executable_path)
    images = macho_images(binary)
    has_profile = root + 'embedded.mobileprovision' in names
    has_resources = root + '_CodeSignature/CodeResources' in names
    signature_present = all(image['codeSignatureCommand'] for image in images) and has_profile and has_resources
    if expected_signing == 'signed':
        require(signature_present, 'Signed IPA is missing its Mach-O signature, provisioning profile or signed resource seal.')
    else:
        require(not has_profile and not has_resources and not any(image['codeSignatureCommand'] for image in images), 'Unsigned IPA unexpectedly contains signing or provisioning data.')
    return {
        'bundleIdentifier': info.get('CFBundleIdentifier'),
        'version': info.get('CFBundleShortVersionString'),
        'deviceFamilies': ['iPhone', 'iPad'],
        'minimumOS': info['MinimumOSVersion'],
        'sdk': sdk_name,
        'executableBytes': len(binary),
        'executableSHA256': hashlib.sha256(binary).hexdigest(),
        'macho': images,
        'signing': expected_signing,
        'signatureStructurePresent': signature_present,
        'appleSignatureTrustCheckedByThisScript': False,
        'installation': 'Requires your own authorized signing before installation.' if expected_signing == 'unsigned' else 'Limited to the devices and permissions of the supplied profile; requires Apple signature validation.',
        'checks': ['IPA layout', 'bundle plist', 'iPhone+iPad families', 'arm64 executable', 'iOS device platform', 'iOS SDK 26+', 'SwiftUI linkage', 'executable permission', 'signing structure'],
    }


def self_test() -> None:
    """Exercise rejection paths with in-memory fixtures; never emit a pretend IPA."""
    def fixture(platform=2, sdk=26, families=(1, 2), executable=b''):
        build = struct.pack('<IIIIII', 0x32, 24, platform, 17 << 16, sdk << 16, 0)
        name = b'/System/Library/Frameworks/SwiftUI.framework/SwiftUI\0'
        name += b'\0' * (-(24 + len(name)) % 8)
        dylib = struct.pack('<IIIIII', 0xC, 24 + len(name), 24, 0, 0, 0) + name
        commands = build + dylib
        binary = executable or struct.pack('<IIIIIIII', 0xFEEDFACF, 0x100000C, 0, 2, 2, len(commands), 0, 0) + commands
        info = {'CFBundlePackageType': 'APPL', 'UIDeviceFamily': list(families), 'CFBundleSupportedPlatforms': ['iPhoneOS'], 'DTSDKName': 'iphoneos26.0', 'MinimumOSVersion': '17.0', 'CFBundleExecutable': 'Komiic', 'CFBundleIdentifier': 'invalid.test.fixture'}
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('Payload/Komiic.app/Info.plist', plistlib.dumps(info))
            entry = zipfile.ZipInfo('Payload/Komiic.app/Komiic')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(entry, binary)
        return buffer
    with zipfile.ZipFile(fixture()) as archive:
        assert inspect_archive(archive, 'unsigned')['deviceFamilies'] == ['iPhone', 'iPad']
    for options in ({'platform': 7}, {'sdk': 25}, {'families': (1,)}, {'executable': b'this is source code, not a compiled executable' * 2}):
        try:
            with zipfile.ZipFile(fixture(**options)) as archive:
                inspect_archive(archive, 'unsigned')
        except InvalidIPA:
            continue
        raise AssertionError(f'Invalid in-memory fixture was accepted: {options}')
    try:
        with zipfile.ZipFile(fixture()) as archive:
            inspect_archive(archive, 'signed')
    except InvalidIPA:
        pass
    else:
        raise AssertionError('Unsigned structure was accepted as signed.')
    print('PASS: 6 in-memory verifier checks; no IPA artifact was created.')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', nargs='?', type=Path)
    parser.add_argument('--expected-signing', choices=['unsigned', 'signed'], default='unsigned')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    options = parser.parse_args()
    try:
        if options.self_test:
            require(options.ipa is None, '--self-test must not be combined with an IPA file.')
            self_test()
            return 0
        require(options.ipa is not None, 'Provide an actual built IPA, or use --self-test.')
        with zipfile.ZipFile(options.ipa) as archive:
            report = inspect_archive(archive, options.expected_signing)
        with options.ipa.open('rb') as source:
            report['ipaSHA256'] = hashlib.file_digest(source, 'sha256').hexdigest()
        rendered = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
        if options.output:
            options.output.parent.mkdir(parents=True, exist_ok=True)
            options.output.write_text(rendered, encoding='utf-8')
        print(rendered, end='')
        return 0
    except (InvalidIPA, OSError, ValueError, KeyError, TypeError, UnicodeError, struct.error, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f'IPA verification failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
