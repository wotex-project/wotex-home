#!/usr/bin/env python3
"""Freeze independent metadata joins; never run the Swift implementation."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'test/fixtures/profiles/native-paired-workspace-selectors-v1.json'


def handle(index, revision=1):
    return {'object_digest': f'{index:064x}', 'first_revision': revision}


def corpus():
    # Expected joins are explicit sets/order, independent of the Swift routine.
    valid = [
        ('empty', [], []),
        ('one', [handle(9, 5)], [handle(9, 5)]),
        ('same-source-passages', [handle(9, 5), handle(9, 5)], [handle(9, 5)]),
        ('reverse', [handle(9, 5), handle(2, 6)], [handle(2, 6), handle(9, 5)]),
        ('interleaved', [handle(9, 5), handle(2, 6), handle(9, 5), handle(2, 6)], [handle(2, 6), handle(9, 5)]),
        ('signed-max', [handle(9, 9223372036854775807)], [handle(9, 9223372036854775807)]),
        ('32-unique', [handle(i, i + 1) for i in range(31, -1, -1)], [handle(i, i + 1) for i in range(32)]),
        ('32-duplicate', [handle(9, 5)] * 32, [handle(9, 5)]),
    ]
    invalid = [
        ('conflict-forward', [handle(9, 5), handle(9, 6)]),
        ('conflict-reverse', [handle(9, 6), handle(9, 5)]),
        ('33-duplicate', [handle(9, 5)] * 33),
        ('extra-key', [dict(handle(9, 5), kind='source')]),
        ('missing-digest', [{'first_revision': 5}]),
        ('missing-revision', [{'object_digest': '9' * 64}]),
        ('zero', [handle(9, 0)]),
        ('negative', [handle(9, -1)]),
        ('overflow', [handle(9, 9223372036854775808)]),
        ('float', [handle(9, 5.0)]),
        ('bool', [handle(9, True)]),
        ('null', [handle(9, None)]),
        ('string', [handle(9, '5')]),
        ('uppercase', [{'object_digest': 'A' * 64, 'first_revision': 5}]),
        ('short', [{'object_digest': 'a' * 63, 'first_revision': 5}]),
        ('long', [{'object_digest': 'a' * 65, 'first_revision': 5}]),
        ('not-hex', [{'object_digest': 'g' * 64, 'first_revision': 5}]),
    ]
    return {
        'oracle': 'independent Python explicit finite handle joins; no Swift import',
        'valid': [{'id': name, 'input': rows, 'expected': expected} for name, rows, expected in valid],
        'invalid': [{'id': name, 'input': rows} for name, rows in invalid],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    data = (json.dumps(corpus(), ensure_ascii=False, indent=2) + '\n').encode()
    if args.check:
        if TARGET.read_bytes() != data:
            raise SystemExit('workspace selector oracle drift')
    else:
        TARGET.write_bytes(data)
    print(f'workspace selector oracle: 8 valid, 17 invalid; sha256 {hashlib.sha256(data).hexdigest()}')


if __name__ == '__main__':
    main()
