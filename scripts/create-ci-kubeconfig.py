#!/usr/bin/env python3
"""Create a private CI kubeconfig without printing credentials."""
import argparse
import base64
import json
import os
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--kubectl', default='kubectl')
parser.add_argument('--kubeconfig', required=True)
parser.add_argument('--output', default='k3s-ci.kubeconfig')
args = parser.parse_args()

def kubectl_json(*arguments):
    result = subprocess.run(
        [args.kubectl, '--kubeconfig', args.kubeconfig, *arguments, '-o', 'json'],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)

source = kubectl_json('config', 'view', '--raw', '--minify')
cluster = source['clusters'][0]['cluster']
if not cluster.get('certificate-authority-data') or cluster.get('insecure-skip-tls-verify'):
    raise SystemExit('A verified TLS cluster configuration is required')

token = None
for _ in range(20):
    secret = kubectl_json('get', 'secret', 'github-deployer-token', '-n', 'default')
    value = secret.get('data', {}).get('token')
    if value:
        token = base64.b64decode(value).decode()
        break
    time.sleep(1)
if not token:
    raise SystemExit('ServiceAccount token has not been populated')

config = {
    'apiVersion': 'v1', 'kind': 'Config',
    'clusters': [{'name': 'hw6', 'cluster': {
        'server': cluster['server'],
        'certificate-authority-data': cluster['certificate-authority-data'],
    }}],
    'users': [{'name': 'github-deployer', 'user': {'token': token}}],
    'contexts': [{'name': 'github-deployer', 'context': {
        'cluster': 'hw6', 'user': 'github-deployer', 'namespace': 'default',
    }}],
    'current-context': 'github-deployer',
}
with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as file:
    json.dump(config, file, indent=2)
    file.write('\n')
print(f'Private CI kubeconfig created: {args.output} (0600); credential not displayed')
