#!/usr/bin/env python3
"""Freeze native original expectations without importing Home, BEAM or Swift."""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / 'fixtures/profiles'
TARGET = FIXTURES / 'native-external-profile-originals-v1.json'
TRUST = 'authority_epoch operation_id expected_revision action artifact_digest expected_trust_revision expected_policy_generation inspection_ref acknowledgement'.split()
TARGET_FIELDS = 'authority_epoch operation_id expected_revision action target_id artifact_digest expected_trust_revision expected_policy_generation expected_selection_revision expected_resource_revision source_ref source_owner_epoch source_selection_sha256 objects acknowledgement'.split()
REF = 'authority_epoch operation_id revision input_sha256 result_sha256'.split()


def wire(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def handle(value):
    return [value['object_digest'], value['first_revision']]


def document(value):
    return [[value['reference'][k] for k in ('id', 'version', 'sha256')], handle(value['object_ref'])]


def objects(value):
    return [handle(value['envelope_ref']), document(value['profile']), [document(d) for d in value['definitions']]]


def original(kind, value):
    if kind == 'inspection':
        body = [value[k] for k in ('authority_epoch', 'operation_id', 'expected_revision')]
        body.append([value['inspection']['reader_basis_sha256']] + objects(value['inspection']))
    else:
        body = [value[k] for k in (TRUST if kind == 'trust' else TARGET_FIELDS)]
        if kind == 'trust' and value['inspection_ref'] is not None:
            body[7] = [value['inspection_ref'][k] for k in REF]
        if kind == 'target' and value['objects'] is not None:
            body[13] = objects(value['objects'])
    return wire(['wotex-home.external-' + kind + '.v1', body])


def read(name):
    return json.loads((FIXTURES / (name + '.json')).read_text())


def allocate():
    valid, invalid, invalid_wire, invalid_json = [], [], [], []

    def yes(name, kind, value, frozen=None):
        encoded = original(kind, value)
        if frozen is not None:
            assert frozen == encoded, name
        valid.append({'id': name, 'kind': kind, 'input': copy.deepcopy(value), 'document': encoded,
                      'sha256': hashlib.sha256(encoded.encode()).hexdigest()})

    def no(name, kind, value):
        invalid.append({'id': name, 'kind': kind, 'input': copy.deepcopy(value)})

    for family in ('temperature', 'research'):
        v = read('external-inspections')[family]
        yes(family + '-inspection', 'inspection', v['input'], v['input_document'])
        for action in ('approve', 'revoke'):
            v = read('external-trust')[family][action]
            yes(family + '-' + action, 'trust', v['input'], v['input_document'])
    for family in ('temperature', 'research', 'multi'):
        for action in ('select', 'revoke'):
            v = read('external-target-selections')[family][action]
            yes(family + '-' + action, 'target', v['input'], v['input_document'])

    bases = {kind: copy.deepcopy(next(v['input'] for v in valid if v['kind'] == kind)) for kind in ('inspection', 'trust', 'target')}
    for kind, base in bases.items():
        for key in ('authority_epoch', 'expected_revision'):
            for bad in (True, 1.0, '1', None, -1, 9223372036854775808):
                value = copy.deepcopy(base); value[key] = bad
                no(kind + '-' + key + '-' + repr(bad), kind, value)
        value = copy.deepcopy(base); value['authority_epoch'] = 9223372036854775807; value['expected_revision'] = 9223372036854775807
        yes(kind + '-signed-max', kind, value)
        for key in base:
            value = copy.deepcopy(base); del value[key]; no(kind + '-missing-' + key, kind, value)
        value = copy.deepcopy(base); value['extra'] = True; no(kind + '-extra', kind, value)
        value = copy.deepcopy(base); value['operation_id'] = 'bad/id'; no(kind + '-operation', kind, value)

    for kind in ('inspection', 'target'):
        base = bases[kind]; key = 'inspection' if kind == 'inspection' else 'objects'
        value = copy.deepcopy(base); value[key]['definitions'] = []; yes(kind + '-empty', kind, value)
        defs = [{'reference': {'id': f'urn:definition:{i:02}', 'version': '1.0.0', 'sha256': f'{i + 1:064x}'},
                 'object_ref': {'object_digest': f'{i + 100:064x}', 'first_revision': i + 1}} for i in range(32)]
        value = copy.deepcopy(base); value[key]['definitions'] = defs; yes(kind + '-32', kind, value)
        for name, changed in [('33', defs + [defs[0]]), ('reverse', list(reversed(defs))), ('duplicate-id', defs[:1] * 2),
                              ('same-digest', [defs[0], dict(defs[1], object_ref=defs[0]['object_ref'])]),
                              ('same-id-new-version', [defs[0], dict(defs[0], reference=dict(defs[0]['reference'], version='2.0.0'))])]:
            value = copy.deepcopy(base); value[key]['definitions'] = changed; no(kind + '-' + name, kind, value)
        value = copy.deepcopy(base); value[key]['definitions'] = [dict(defs[0], object_ref=value[key]['profile']['object_ref'])]
        yes(kind + '-shape-only-profile-alias', kind, value)
        for version in ('65535.65535.65535', '0.0.0'):
            value = copy.deepcopy(base); value[key]['profile']['reference']['version'] = version; yes(kind + '-version-' + version, kind, value)
        for version in ('01.0.0', '65536.0.0', '1.0', '1.0.0\n'):
            value = copy.deepcopy(base); value[key]['profile']['reference']['version'] = version; no(kind + '-version-' + repr(version), kind, value)
        for field in ('first_revision', 'object_digest'):
            value = copy.deepcopy(base); value[key]['envelope_ref'][field] = 0 if field == 'first_revision' else 'A' * 64; no(kind + '-handle-' + field, kind, value)

    uri_yes = ['a:', 'urn:', 'urn:bad%ZZ', 'https://', 'https://x/a?q=ok#f', 'x://:80', 'x://user:pw@/',
               'https://x:65536/a', 'x://x:99999', 'x://x:00001', 'x://[::1]/', 'x://[::ffff:192.0.2.1]/',
               'x://[::1]abc', 'x://[::1].', 'x://[::1]123:80/a', 'urn:' + 'a' * 252, "urn:a!$&'()*+,;=:@/~._-%"]
    uri_no = ['relative', '1scheme:a', 'urn:bad space', 'urn:λ', 'urn:a\\b', 'urn:a"b', 'urn:[x]', 'urn:a#b#c',
              'x://[v1.a]/', 'x://[bad]/', 'x://a@b@c/', 'x://x:abc/', 'x://x:100000', 'x://x:000001',
              'x://[::1]g', 'x://h[a]', 'urn:' + 'a' * 253, 'urn:a|b', 'urn:a\u200b']
    uri_no += ['x://[::1' + chr(code) + 'suffix]' for code in list(range(33)) + [127]]
    for accepted, uris in [(True, uri_yes), (False, uri_no)]:
        for index, uri in enumerate(uris):
            value = copy.deepcopy(bases['inspection']); value['inspection']['profile']['reference']['id'] = uri
            (yes if accepted else no)('uri-' + str(accepted) + '-' + str(index), 'inspection', value)

    value = copy.deepcopy(bases['trust']); value['inspection_ref']['authority_epoch'] = 2; yes('historical-inspection-epoch', 'trust', value)
    for key, bad in [('acknowledgement', None), ('action', 'revoke'), ('artifact_digest', 'A' * 64), ('inspection_ref', None), ('expected_policy_generation', True)]:
        value = copy.deepcopy(bases['trust']); value[key] = bad; no('trust-' + key, 'trust', value)
    revoke = read('external-trust')['temperature']['revoke']['input']
    for key in ('inspection_ref', 'acknowledgement'):
        value = copy.deepcopy(revoke); value[key] = bases['trust'][key]; no('trust-revoke-' + key, 'trust', value)
    for key, bad in [('source_ref', 'bad/id'), ('source_owner_epoch', 'F' * 32), ('source_selection_sha256', None), ('objects', None), ('acknowledgement', 'yes'), ('action', 'revoke')]:
        value = copy.deepcopy(bases['target']); value[key] = bad; no('target-' + key, 'target', value)
    revoke = read('external-target-selections')['temperature']['revoke']['input']
    for key in ('source_ref', 'source_owner_epoch', 'source_selection_sha256', 'objects', 'acknowledgement'):
        value = copy.deepcopy(revoke); value[key] = bases['target'][key]; no('target-revoke-' + key, 'target', value)

    for vector in valid[:12]:
        text = vector['document']; kind = vector['kind']
        for label, changed in [('space', ' ' + text), ('trailing', text + '\n'), ('escape', text.replace('wotex', '\\u0077otex', 1)),
                               ('kind', text.replace('.v1', '.v2', 1)), ('native-map', wire(vector['input']))]:
            invalid_wire.append({'id': vector['id'] + '-' + label, 'kind': kind, 'payload_base64': base64.b64encode(changed.encode()).decode()})
    for name, data in [('deep', b'[' * 9 + b'0' + b']' * 9), ('array', ('[' + ','.join(['null'] * 257) + ']').encode()),
                       ('nodes', ('[' + ','.join(['[' + ','.join(['0'] * 256) + ']'] * 17) + ']').encode()),
                       ('string', json.dumps('a' * 4097).encode()), ('integer', b'9223372036854775808'), ('utf8', b'"\xff"'), ('empty', b''), ('roots', b'[][]')]:
        invalid_wire.append({'id': name, 'kind': 'target', 'payload_base64': base64.b64encode(data).decode()})
    native_base = wire(bases['trust'])
    duplicate = native_base.replace('"authority_epoch":1', '"authority_epoch":1,"authority_epoch":1', 1)
    decoded_duplicate = native_base.replace('"authority_epoch":1', '"authority_epoch":1,"authority\\u005fepoch":1', 1)
    for name, data in [('duplicate', duplicate), ('decoded-duplicate', decoded_duplicate),
                       ('deep', '[' * 9 + '0' + ']' * 9), ('keys', wire({str(i): 0 for i in range(33)})),
                       ('oversize', ' ' * 131073), ('float', wire(dict(bases['trust'], expected_revision=1.0)))]:
        invalid_json.append({'id': name, 'kind': 'target' if name == 'oversize' else 'trust', 'payload_base64': base64.b64encode(data.encode()).decode()})
    control = copy.deepcopy(bases['inspection']); control['inspection']['profile']['reference']['id'] = 'x://[::1\x00suffix]'
    invalid_json.append({'id': 'literal-control-before-C-parser', 'kind': 'inspection', 'payload_base64': base64.b64encode(wire(control).encode()).decode()})
    return {'oracle': 'independent Python array layouts and explicit boundary cases; no Home/BEAM/Swift import',
            'valid': valid, 'invalid': invalid, 'invalid_wire': invalid_wire, 'invalid_json': invalid_json}


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    corpus = allocate(); data = (json.dumps(corpus, ensure_ascii=False, indent=2) + '\n').encode()
    if args.check:
        if TARGET.read_bytes() != data: raise SystemExit('native external original corpus drift')
    else: TARGET.write_bytes(data)
    print('native external originals:', ', '.join(f'{key}={len(corpus[key])}' for key in ('valid', 'invalid', 'invalid_wire', 'invalid_json')), hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
