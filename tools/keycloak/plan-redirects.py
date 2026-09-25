#!/usr/bin/env python3
"""Prepare an additive Hawtio redirect update offline; never contact Keycloak."""

import argparse
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


def strings(value, label):
    if not isinstance(value, list) or any(not isinstance(v, str) or not v for v in value):
        raise ValueError(f"{label} must be a list of nonempty strings")
    return value


def plan(export, inventory, issuer, client_id):
    parsed = urlsplit(issuer)
    realm = unquote(parsed.path.rsplit('/realms/', 1)[-1])
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or
            parsed.password or parsed.query or parsed.fragment or
            '/realms/' not in parsed.path or not realm or '/' in realm):
        raise ValueError('issuer must be an HTTPS realm URL')
    if 'placeholder' in (issuer + client_id).lower() or parsed.hostname.endswith('.invalid'):
        raise ValueError('replace placeholder issuer and client ID')
    if not client_id or export.get('realm') != realm:
        raise ValueError('export realm does not match issuer, or client ID is empty')
    matches = [c for c in export.get('clients', []) if c.get('clientId') == client_id]
    if len(matches) != 1:
        raise ValueError('export must contain exactly one matching existing client')
    groups = [c for c in inventory.get('clients', [])
              if c.get('issuerUrl') == issuer and c.get('clientId') == client_id]
    if len(groups) != 1:
        raise ValueError('inventory must contain exactly one matching issuer/client group')
    before = strings(matches[0].get('redirectUris'), 'existing redirectUris')
    requested = strings(groups[0].get('redirectUris'), 'inventory redirectUris')
    if not requested:
        raise ValueError('inventory redirectUris is empty')
    for uri in requested:
        url = urlsplit(uri)
        if (url.scheme != 'https' or not url.hostname or url.netloc != url.hostname or
                url.path != '/console' or url.query or url.fragment or '*' in uri or
                'placeholder' in uri.lower() or url.hostname.endswith('.invalid') or
                any(c.isspace() for c in uri)):
            raise ValueError('inventory contains a non-exact or placeholder HTTPS console URL')
    # The existing apply wrapper enables config-cli substitution. Never let
    # exported strings become substitution expressions in the generated input.
    if any('$(' in value for value in [realm, client_id, *before, *requested]):
        raise ValueError('substitution expressions are not allowed in redirect plans')
    added = sorted(set(requested) - set(before))
    after = before + added
    warnings = []
    if '*' in before:
        warnings.append('Unrestricted * is preserved; explicit additions do not restrict redirects. Review removal separately.')
    result = {
        'issuerUrl': issuer, 'realm': realm, 'clientId': client_id,
        'changed': bool(added), 'before': before, 'added': added,
        'removed': [], 'after': after, 'warnings': warnings,
    }
    desired = {'realm': realm, 'clients': [{'clientId': client_id, 'redirectUris': after}]}
    return result, desired


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', required=True, type=Path, help='Fresh realm-export.json from toolkit')
    parser.add_argument('--inventory', required=True, type=Path, help='hawtio-redirects.py JSON report')
    parser.add_argument('--issuer', required=True, help='Exact issuerUrl selecting inventory group')
    parser.add_argument('--client-id', required=True)
    parser.add_argument('--output-dir', type=Path, help='Create a NEW directory with review and desired files')
    args = parser.parse_args()
    try:
        review, desired = plan(json.loads(args.export.read_text()),
                               json.loads(args.inventory.read_text()), args.issuer, args.client_id)
        if args.output_dir:
            args.output_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
            (args.output_dir / 'review.json').write_text(json.dumps(review, indent=2) + '\n')
            if review['changed']:
                target = args.output_dir / 'desired'
                target.mkdir(mode=0o700)
                (target / 'hawtio-redirects.json').write_text(json.dumps(desired, indent=2) + '\n')
        print(json.dumps(review, indent=2))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f'plan-redirects: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
