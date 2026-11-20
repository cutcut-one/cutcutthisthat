#!/usr/bin/env python3
"""Kế hoạch nhiều gói → issue runner. Mỗi '### <ID> — <tên>' + dòng 'meta: <nền tảng> | <model> | chờ: A, B'.
Dùng: plan-to-issues.py <plan.md> --repo nguyenphp/vibecut --base desktop/main --doc docs/desktop/plan.md [--create]
Không --create = in thử. Chạy lại an toàn: bỏ gói đã có issue (dấu <!-- plan:<base>:<ID> -->)."""
import argparse, json, re, subprocess, sys

def parse(text):
    pk, cur = [], None
    for line in text.splitlines():
        m = re.match(r'^### (\S+) — (.+)$', line)
        if m:
            cur = {'id': m[1], 'title': m[2].strip(), 'lines': []}; pk.append(cur); continue
        if line.startswith('## ') or line.startswith('---'):
            cur = None; continue
        if cur is None: continue
        mm = re.match(r'^meta: *([\w-]+) *\| *(\w+) *\| *chờ: *(.*)$', line)
        if mm:
            cur['platform'], cur['model'] = mm[1], mm[2]
            cur['deps'] = [d.strip() for d in mm[3].split(',') if d.strip() not in ('', '—', '-')]
        else:
            cur['lines'].append(line)
    for p in pk:
        assert 'platform' in p, f"{p['id']} thiếu meta"
    return pk

def body_of(p, base, doc, nums, read, goal, prefix='desktop'):
    tasks, done, cur = [], '', None
    for l in p['lines']:
        if l.startswith('Xong khi:'): done = l[len('Xong khi:'):].strip(); cur = None
        elif l.startswith('- '): cur = '- [ ] ' + l[2:]; tasks.append(cur)
        elif l.startswith('  ') and tasks: tasks[-1] += ' ' + l.strip()
    if not tasks: tasks = [f'- [ ] Làm đủ gói {p["id"]} theo {doc}']
    wait = ', '.join(f'#{nums[d]}' for d in p['deps'] if d in nums)
    return '\n'.join([
        f'Từ kế hoạch `{doc}` (nhánh `{base}`) — gói **{p["id"]}**: {p["title"]}', '',
        '## Mục tiêu', f'{p["title"]} — {goal}', '',
        '## Task', *tasks, '',
        '## Xong khi', f'- {done or "test xanh"}', '- `$TEST_CMD` xanh (build + toàn bộ test)', '',
        '## Ghi chú',
        f'- ĐỌC TRƯỚC trên nhánh `{base}`: {read}, mục {p["id"]} của `{doc}`.',
        *(['- Code Swift gốc là chân lý: lệch tài liệu → theo code, sửa tài liệu trong cùng PR.'] if prefix == 'desktop' else ['- Hợp đồng `docs/contract/` là chân lý: thấy sai → ghi vào PR, không tự sửa hợp đồng.']), '',
        f'Nhánh gốc: {base}', *( [f'Chờ: {wait}'] if wait else [] ), '',
        f'<!-- plan:{base}:{p["id"]} -->'])

def gh(*a):
    import time
    for i in range(5):  # GitHub hay từ chối khi tạo dồn (secondary rate limit) → chờ rồi thử lại
        r = subprocess.run(['gh', *a], capture_output=True, text=True)
        if r.returncode == 0: return r.stdout
        sys.stderr.write(r.stderr[-300:]); time.sleep(20 * (i + 1))
    raise SystemExit('gh lỗi 5 lần')

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('plan'); ap.add_argument('--repo', required=True)
    ap.add_argument('--base', required=True); ap.add_argument('--doc', required=True); ap.add_argument('--create', action='store_true')
    ap.add_argument('--read', default='`docs/desktop/spec.md`, `docs/desktop/engine-contract.md`, `docs/desktop/ui-inventory.md`')
    ap.add_argument('--goal', default='cho CutCut Desktop (Windows + Linux, lõi C++, giao diện y app Mac).')
    ap.add_argument('--prefix', default='desktop')
    ap.add_argument('--label-extra', action='append', default=[], help='nhãn thêm cho mọi issue, vd repo:clip-factory')
    ap.add_argument('--only', default='', help='chỉ tạo các gói này, vd S1,S2 (gói chờ ngoài danh sách coi như đã xong)')
    a = ap.parse_args(); pk = parse(open(a.plan, encoding='utf-8').read())
    if a.only:
        keep = set(a.only.split(',')); pk = [p for p in pk if p['id'] in keep]
        for p in pk: p['deps'] = [d for d in p['deps'] if d in keep]
    ids = {p['id'] for p in pk}
    for p in pk:
        bad = [d for d in p['deps'] if d not in ids]; assert not bad, f'{p["id"]} chờ gói lạ {bad}'
    order, seen = [], set()
    def visit(p, stack=()):
        if p['id'] in seen: return
        assert p['id'] not in stack, f'vòng phụ thuộc {stack}'
        for d in p['deps']: visit(next(x for x in pk if x['id'] == d), stack + (p['id'],))
        seen.add(p['id']); order.append(p)
    for p in pk: visit(p)
    nums = {}
    if a.create:
        for it in json.loads(gh('issue', 'list', '-R', a.repo, '--state', 'all', '-L', '500', '--json', 'number,body')):
            m = re.search(rf'<!-- plan:{re.escape(a.base)}:(\S+) -->', it['body'] or '')
            if m: nums[m[1]] = it['number']
    bots, k = ['bot:ironman', 'bot:spiderman', 'bot:queenie'], 0
    for p in order:
        b = body_of(p, a.base, a.doc, nums, a.read, a.goal, a.prefix)
        labels = [p['platform'], f'model:{p["model"]}', bots[k % 3], 'ci-run', *a.label_extra]; k += 1
        title = f'[{a.prefix}/{p["platform"]}] {p["id"]} {p["title"]}'
        if not a.create:
            print(f'{p["id"]:6} {",".join(labels):45} chờ {p["deps"] or "-"}'); nums[p['id']] = f'?{p["id"]}'; continue
        if p['id'] in nums: print(f'{p["id"]}: có rồi #{nums[p["id"]]}'); continue
        args = ['issue', 'create', '-R', a.repo, '--title', title, '--body', b]
        for l in labels: args += ['--label', l]
        nums[p['id']] = int(gh(*args).strip().rsplit('/', 1)[1]); print(f'{p["id"]} → #{nums[p["id"]]}', flush=True); __import__('time').sleep(3)
    print(f'{len(order)} gói')

if __name__ == '__main__':
    main()
