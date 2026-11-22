"""Read-only checks against both public Komiic catalog origins; no account cookies."""
import json, urllib.request, datetime
from pathlib import Path

fields = 'id title status imageUrl authors { id name } categories { id name } dateUpdated monthViews views favoriteCount lastBookUpdate lastChapterUpdate contentType warnings'
def call(origin, name, query, variables):
    req = urllib.request.Request(origin + '/api/query', data=json.dumps(dict(operationName=name, query=query, variables=variables)).encode(), headers={'Content-Type':'application/json', 'Origin':origin, 'Referer':origin+'/', 'User-Agent':'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=30) as res:
        return res.status, json.load(res)

checks = []
for mode, origin in [('REGULAR','https://komiic.cc'), ('H_MANGA','https://h.komiic.cc')]:
    pagination = dict(limit=2, offset=0, orderBy='DATE_UPDATED', asc=False)
    operations = [
        ('recentUpdate', 'query recentUpdate($pagination: Pagination!) { comics: recentUpdate(pagination: $pagination) { '+fields+' } }', {'pagination':pagination}),
        ('newComics','query newComics($pagination: Pagination!) { comics: comicByCategories(categoryId: [], pagination: $pagination) { '+fields+' } }', {'pagination':dict(pagination, orderBy='DATE_CREATED')}),
        ('hotComics','query hotComics($pagination: Pagination!) { comics: hotComics(pagination: $pagination) { '+fields+' } }', {'pagination':dict(pagination, orderBy='MONTH_VIEWS')}),
        ('topRecommendedComics','query topRecommendedComics($pagination: Pagination!, $adult: Boolean, $contentType: ContentType) { comics: topRecommendedComics(period: MONTH, pagination: $pagination, adult: $adult, contentType: $contentType) { '+fields+' } }', {'pagination':pagination,'adult':mode=='H_MANGA','contentType':mode}),
        ('accountIdentity','query accountIdentity { account { id } }', {}),
    ]
    for name, query, variables in operations:
        status, result = call(origin, name, query, variables)
        rows = [row for row in ((result.get('data') or {}).get('comics', []) or []) if row]
        item = dict(mode=mode, origin=origin, operation=name, status=status, count=len(rows), contentTypes=sorted(set(x.get('contentType','') for x in rows)), errors=result.get('errors'), account=(result.get('data') or {}).get('account'))
        checks.append(item)
        print(json.dumps(item,ensure_ascii=True))
checked_date = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).date().isoformat()
out = dict(checkedDate=checked_date, source='https://komiic.cc/assets/index-Qe6s1nt9.js', modeSelection='Official h. origin plus explicit adult/contentType for recommendations', checks=checks, officialWarningTags=['血腥','獵奇','暴力','性暴力','性描寫','自殺','恐怖','近親','NTR','BL','百合'], warningActions=dict(show=None,blur='WARN',hide='HIDE'), authenticationLimit='Authenticated mutations/profile collections inferred from first-party script; no user credentials were supplied. No quota bypass or simulated profile data.')
report = Path(__file__).resolve().parents[1] / 'docs/v0.4.0-api.json'
with report.open('w',encoding='utf-8') as f:
    json.dump(out,f,ensure_ascii=False,indent=2)
failures = [item for item in checks if item['operation'] != 'accountIdentity'
            and (item['status'] != 200 or item['errors'] or item['count'] == 0 or item['contentTypes'] != [item['mode']])]
if failures:
    raise SystemExit('FAIL: at least one public feed did not match its selected content mode')
print('PASS: all eight public feeds returned the selected content mode')
