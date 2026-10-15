#!/usr/bin/env python3
"""Freeze builder expectations independently of Home/Swift implementations."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import native_external_profile_originals_oracle as wire

ROOT = Path(__file__).resolve().parents[1] / 'fixtures/profiles'
TARGET = ROOT / 'native-external-profile-builders-v1.json'
REF = 'authority_epoch operation_id revision input_sha256 result_sha256'.split()


def load(name):
    return json.loads((ROOT / (name + '.json')).read_text())


def snapshot(kind, fields, family):
    source = load('external-source-selections')[family]
    inspection = load('external-inspections')[family]['receipt']
    manifest = load('external-trust')[family]
    basis = dict(principal_id='operator:builder', authority_epoch=fields['authority_epoch'],
                 store_revision=fields['expected_revision'], policy_generation=fields.get('expected_policy_generation', 0))
    reader = source['data']['reader_basis_sha256']
    context = dict(basis, format='wotex-home.external-profile-context@1', maintenance='maintenance' if kind != 'inspection' else 'normal',
                   maintenance_revision=1 if kind != 'inspection' else 0,
                   reader=dict(state='available', basis_sha256=reader, reason=None))
    artifact = dict(basis, format='wotex-home.external-inspection-artifact@1',
                    inspection_ref={k: inspection[k] for k in REF}, artifact=manifest['artifact'], artifact_digest=manifest['artifact_digest'])
    item = dict(artifact_digest=manifest['artifact_digest'], id=manifest['artifact']['id'], version=manifest['artifact']['version'],
                trust_author='operator:builder', trust_revision=fields.get('expected_trust_revision', 0), trust_generation=1,
                state='approved', reader_basis_sha256=reader)
    catalogue = {k: basis[k] for k in ('authority_epoch', 'store_revision', 'policy_generation')}
    catalogue['items'] = [] if fields.get('action') == 'approve' else [item]
    row = {k: source['data'][k] for k in 'source_ref reader_basis_sha256 source_epoch source_generation method trust policy_sha256'.split()}
    row['source_selection_sha256'] = source['sha256']
    sources = dict(basis, format='wotex-home.external-source-catalogue@1', state='available', reason=None,
                   owner_epoch=fields.get('source_owner_epoch') or 'a' * 32, sources=[row])
    absent = fields.get('expected_selection_revision', 0) == 0
    target = dict(basis, format='wotex-home.external-target-basis@1', target_id=fields.get('target_id', 'sensor:external'),
                  state='absent' if absent else 'selected', selection_revision=fields.get('expected_selection_revision', 0),
                  selection_generation=0 if absent else 1, resource_revision=fields.get('expected_resource_revision', 0),
                  binding_revision=fields.get('expected_selection_revision', 0),
                  artifact_digest=None if absent else manifest['artifact_digest'], trust_revision=0 if absent else fields['expected_trust_revision'])
    objects = copy.deepcopy(load('external-inspections')[family]['input']['inspection'])
    del objects['reader_basis_sha256']
    return dict(context=context, catalogue=catalogue, artifact=artifact, inspection=inspection, target=target,
                sources=sources, objects=objects, source=row['source_ref'], operation=fields['operation_id'],
                chosen_artifact=manifest['artifact_digest'])


def allocate():
    valid, invalid = [], []
    for family in ('temperature', 'research'):
        ins, trust, target = load('external-inspections')[family], load('external-trust')[family], load('external-target-selections')[family]
        for method, kind, vector in [('inspection', 'inspection', ins), ('approve', 'trust', trust['approve']),
                                     ('revokeTrust', 'trust', trust['revoke']), ('select', 'target', target['select']),
                                     ('revokeTarget', 'target', target['revoke'])]:
            fields = copy.deepcopy(vector['input'])
            inputs = snapshot(kind, fields, family)
            if method in ('revokeTrust', 'revokeTarget'):
                inputs['context']['reader'] = dict(state='unavailable', basis_sha256=None, reason='external_reader_unavailable')
            encoded = wire.original(kind, fields)
            assert encoded == vector['input_document']
            case = dict(id=family+'-'+method, method=method, kind=kind, inputs=inputs, expected=fields,
                        document=encoded, sha256=hashlib.sha256(encoded.encode()).hexdigest())
            valid.append(case)
            def no(suffix, change, reason='guard'):
                bad = copy.deepcopy(case); bad.pop('expected'); bad.pop('document'); bad.pop('sha256')
                bad['id'] += '-' + suffix; bad['error'] = reason; change(bad['inputs']); invalid.append(bad)
            no('operation', lambda i: i.update(operation='bad/id'), 'input')
            no('principal', lambda i: i['context'].update(principal_id='bad/id'), 'input')
            no('future-import', lambda i: i['objects']['envelope_ref'].update(first_revision=i['context']['store_revision']+1)) if method in ('inspection', 'select') else None
            if method != 'inspection':
                no('maintenance', lambda i: i['context'].update(maintenance='normal', maintenance_revision=0))
                no('catalogue-revision', lambda i: i['catalogue'].update(store_revision=i['catalogue']['store_revision']+1))
                no('catalogue-policy', lambda i: (i['context'].update(policy_generation=i['context']['policy_generation']+1)))
            if method in ('inspection', 'approve', 'select'):
                no('reader-unavailable', lambda i: i['context'].update(reader=dict(state='unavailable', basis_sha256=None, reason='external_reader_unavailable')))
            if method in ('approve', 'select'):
                no('artifact-principal', lambda i: i['artifact'].update(principal_id='other:actor'))
                no('artifact-epoch', lambda i: i['artifact'].update(authority_epoch=3))
                no('artifact-digest', lambda i: i['artifact'].update(artifact_digest='0'*64), 'input')
            if method == 'approve':
                def approved(i):
                    item = copy.deepcopy(snapshot('trust', dict(fields, action='revoke', expected_trust_revision=1), family)['catalogue']['items'][0])
                    item['state'] = 'approved'; i['catalogue']['items']=[item]
                    i['catalogue']['policy_generation']=1; i['context']['policy_generation']=1; i['artifact']['policy_generation']=1
                no('already-approved', approved)
                def unavailable(i):
                    approved(i); i['catalogue']['items'][0]['state']='author_unavailable'
                no('author-unavailable-is-not-revoked', unavailable)
                no('reader-changed', lambda i: i['context']['reader'].update(basis_sha256='0'*64))
                no('receipt-join', lambda i: i['inspection'].update(operation_id='inspection:other'))
            if method in ('revokeTrust', 'revokeTarget', 'select'):
                no('missing-item', lambda i: i['catalogue'].update(items=[]))
            if method in ('select', 'revokeTrust'):
                no('revoked-item', lambda i: i['catalogue']['items'][0].update(state='revoked', reader_basis_sha256=None))
            if method == 'select':
                no('source-missing', lambda i: i.update(source='source:absent'))
                no('source-reader', lambda i: i['sources']['sources'][0].update(reader_basis_sha256='0'*64))
                no('source-principal', lambda i: i['sources'].update(principal_id='other:actor'))
                no('source-unavailable', lambda i: i['sources'].update(state='unavailable', owner_epoch=None, sources=[], reason='external_source_unavailable'))
                no('object-join', lambda i: i['objects']['profile']['object_ref'].update(object_digest='0'*64))
                no('target-principal', lambda i: i['target'].update(principal_id='other:actor'))
            if method == 'revokeTarget':
                no('already-revoked', lambda i: i['target'].update(state='revoked'))
                no('trust-join', lambda i: i['target'].update(trust_revision=i['target']['trust_revision']-1))

    # New expectations are computed by this independent oracle, never by a builder.
    def yes(case, name, change):
        case = copy.deepcopy(case); case['id']=name; change(case)
        encoded = wire.original(case['kind'],case['expected']); case.update(document=encoded,sha256=hashlib.sha256(encoded.encode()).hexdigest())
        valid.append(case)
    base = valid[0]
    def many(c):
        definitions=[]
        for index in range(32):
            definitions.append(dict(reference=dict(id=f'urn:definition:{index:02}',version='1.0.0',sha256=f'{index+100:064x}'),
                                    object_ref=dict(object_digest=f'{index+200:064x}',first_revision=1)))
        c['inputs']['objects']['definitions']=definitions
        c['expected']['inspection']['definitions']=definitions
    yes(base,'32-definitions',many)
    approve = next(c for c in valid if c['id']=='temperature-approve')
    def historical(c):
        c['inputs']['context']['authority_epoch']=2; c['inputs']['catalogue']['authority_epoch']=2
        c['inputs']['artifact']['authority_epoch']=2; c['expected']['authority_epoch']=2
    yes(approve,'historical-inspection-epoch',historical)
    def reapprove(c):
        i=c['inputs']; i['context'].update(store_revision=20,policy_generation=2)
        i['artifact'].update(store_revision=20,policy_generation=2)
        item=copy.deepcopy(snapshot('trust',dict(c['expected'],action='revoke',expected_trust_revision=15), 'temperature')['catalogue']['items'][0])
        item.update(state='revoked',trust_generation=2,reader_basis_sha256=None)
        i['catalogue'].update(store_revision=20,policy_generation=2,items=[item])
        c['expected'].update(expected_revision=20,expected_policy_generation=2,expected_trust_revision=15)
    yes(approve,'reapprove-revoked-artifact',reapprove)
    revoke=next(c for c in valid if c['id']=='temperature-revokeTrust')
    yes(revoke,'withdraw-unavailable-author',lambda c:c['inputs']['catalogue']['items'][0].update(state='author_unavailable'))
    selection=next(c for c in valid if c['id']=='temperature-select')
    def replace(c):
        i=c['inputs']; rev=30
        for member in ('context','artifact','target','sources'):
            i[member].update(store_revision=rev,policy_generation=3)
        i['catalogue'].update(store_revision=rev,policy_generation=3)
        i['target'].update(state='selected',selection_revision=20,selection_generation=2,resource_revision=1,binding_revision=20,artifact_digest='0'*64,trust_revision=15)
        i['catalogue']['items'][0]['trust_revision']=25
        old=dict(i['catalogue']['items'][0],id='prior:artifact',artifact_digest='0'*64,trust_revision=15)
        i['catalogue']['items'].append(old);i['catalogue']['items'].sort(key=lambda item:(item['id'],item['version']))
        c['expected'].update(expected_revision=rev,expected_policy_generation=3,expected_trust_revision=25,expected_selection_revision=20,expected_resource_revision=1)
    yes(selection,'replace-with-different-approved-artifact',replace)
    objects_valid=[]; objects_invalid=[]
    for case in [valid[0], next(c for c in valid if c['id']=='32-definitions')]:
        fields=copy.deepcopy(case['inputs']['objects']); document=wire.wire(wire.objects(fields))
        objects_valid.append(dict(id=case['id'],fields=fields,document=document))
    max_fields=copy.deepcopy(objects_valid[0]['fields']);max_fields['envelope_ref']['first_revision']=9223372036854775807
    objects_valid.append(dict(id='s64-handle',fields=max_fields,document=wire.wire(wire.objects(max_fields))))
    base_objects=objects_valid[0]['fields']
    for key in ['envelope_ref','profile','definitions']:
        fields=copy.deepcopy(base_objects);del fields[key];objects_invalid.append(fields)
    fields=copy.deepcopy(base_objects);fields['extra']=None;objects_invalid.append(fields)
    for bad in [True,1.0,'1',0,-1,9223372036854775808]:
        fields=copy.deepcopy(base_objects);fields['envelope_ref']['first_revision']=bad;objects_invalid.append(fields)
    for bad in ['relative','urn:bad space','urn:λ','x://[bad]/']:
        fields=copy.deepcopy(base_objects);fields['profile']['reference']['id']=bad;objects_invalid.append(fields)
    for bad in ['01.0.0','65536.0.0','1.0']:
        fields=copy.deepcopy(base_objects);fields['profile']['reference']['version']=bad;objects_invalid.append(fields)
    many=copy.deepcopy(objects_valid[1]['fields'])
    extra=copy.deepcopy(many['definitions'][-1]);extra['reference'].update(id='urn:definition:32');extra['object_ref'].update(object_digest='f'*64)
    duplicate_digest=copy.deepcopy(many['definitions'][:2]);duplicate_digest[1]['object_ref']['object_digest']=duplicate_digest[0]['object_ref']['object_digest']
    for definitions in [many['definitions'][::-1],many['definitions']+[extra], [many['definitions'][0],many['definitions'][0]],duplicate_digest]:
        fields=copy.deepcopy(base_objects);fields['definitions']=definitions;objects_invalid.append(fields)
    canonical=objects_valid[0]['document']
    wire_invalid=['',canonical+'\n',' '+canonical,'[]','[null,null,[]]',canonical[:-1]+',0]',wire.wire(dict(extra=True)), 'x'*16385]
    return dict(format='wotex-home.native-external-builders-oracle@1',valid=valid,invalid=invalid,
                objects_valid=objects_valid,objects_invalid=objects_invalid,objects_wire_invalid=wire_invalid)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    text=json.dumps(allocate(),ensure_ascii=False,indent=2,sort_keys=True)+'\n'
    if args.check:
        assert TARGET.read_text()==text, 'builder vectors drifted'
    else:
        TARGET.write_text(text)
    data=json.loads(text);print(f"{len(data['valid'])} accepted, {len(data['invalid'])} refused builder vectors")

if __name__=='__main__':main()
