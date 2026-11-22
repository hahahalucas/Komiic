"""Inspect only public first-party API contracts. Never signs in or sends a mutation."""
import concurrent.futures
import json
import re
import urllib.request


def inspect(origin):
    headers = {'User-Agent': 'Mozilla/5.0', 'Origin': origin, 'Referer': origin + '/'}
    def read(url):
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=15) as response:
            return response.read().decode('utf-8')
    report = {'origin': origin}
    try:
        ref = 'kind name ofType { kind name ofType { kind name ofType { kind name } } }'
        fields = 'fields { name args { name defaultValue type { ' + ref + ' } } type { ' + ref + ' } }'
        query = 'query AppCollectionSchema { __schema { queryType { ' + fields + ' } mutationType { ' + fields + ' } } }'
        request = urllib.request.Request(origin + '/api/query',
            data=json.dumps({'operationName': 'AppCollectionSchema', 'query': query, 'variables': {}}).encode(),
            headers=dict(headers, **{'Content-Type': 'application/json'}))
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
        schema = (result.get('data') or {}).get('__schema')
        if schema:
            report['schema'] = {root: [field for field in (schema.get(root) or {}).get('fields', [])
                if re.search('block|folder', field['name'], re.I)] for root in ['queryType', 'mutationType']}
        else:
            report['schemaErrors'] = result.get('errors')
        html = read(origin)
        scripts = re.findall(r'<script[^>]+src="([^"]+)"', html)
        matches = []
        for source in scripts[:3]:
            script = read(origin + source if source.startswith('/') else source)
            # Include complete nearby query strings, not account contents or cookies.
            for match in re.finditer(r'(?:query|mutation)\s+\w*(?:[Bb]lock|[Ff]older)\w*', script):
                matches.append(script[max(0, match.start() - 40):match.start() + 1800])
        report['firstPartyOperations'] = matches[:30]
    except Exception as error:
        report['error'] = str(error)
    return report


if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        reports = list(executor.map(inspect, ['https://komiic.cc', 'https://h.komiic.cc']))
    print(json.dumps(reports, ensure_ascii=False, indent=2))
