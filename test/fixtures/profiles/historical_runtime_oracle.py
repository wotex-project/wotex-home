#!/usr/bin/env python3
"""Freeze canonical history witnesses independently of Home/producer codecs."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).parent
path = root / 'historical-runtime.json'
record = json.loads(path.read_text())
producer = record['producer']

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))

def digest(prefix, text):
    return hashlib.sha256((prefix+'\n'+text).encode()).hexdigest()

def chunks(text):
    raw=text.encode(); out=[]
    while raw:
        n=min(4096,len(raw))
        while True:
            try: out.append(raw[:n].decode()); break
            except UnicodeDecodeError: n-=1
        raw=raw[n:]
    return out

wire=[producer[k] for k in ['format','source_revision','core_runtime_sha256','runtime_runtime_sha256','profiles_runtime_sha256']]
base=json.loads((root/'external-source-selections.json').read_text())['temperature']['inputs']
inputs={'source':base['source'],'reader':base['reader'],'channels':base['channels']}
inputs['reader']['installed']['producer']=producer
body=canonical(inputs); reader=canonical(inputs['reader']); policy=canonical(inputs['channels'])
sha=digest('wotex-home.external-source-selection@1',body)
source=canonical(['wotex-home.retained-source@1','a'*32,sha,chunks(body),chunks(reader),chunks(policy)])
record.update({'wire':wire,'wire_document':canonical(wire),'source_document':source,
               'source_sha256':sha,'reader_basis_sha256':digest('wotex-home.external-reader@1',reader),
               'policy_sha256':digest('wotex-home.external-source-policy@1',policy)})
text=canonical(record)+'\n'
import sys
if '--check' in sys.argv:
    assert path.read_text()==text,'historical witness drift'
    print('independent historical runtime/source witnesses verified')
else:
    path.write_text(text)
