import { useMemo, useState } from 'react'
import { Field, Input } from './form'
import { Sheet } from './Sheet'
import { Badge, Button } from './ui'

export interface MemberOption {
  user_id: string
  name: string
  level: string | null
}

/** 정기운동 고정 참석자 고르기: 고른 사람은 칩으로, 고르기는 시트에서 (검색·체크) */
export function FixedMembersField({
  members,
  value,
  capacity,
  onChange,
}: {
  members: MemberOption[]
  value: string[]
  capacity: number
  onChange: (ids: string[]) => void
}) {
  const [open, setOpen] = useState(false)
  const byId = useMemo(() => new Map(members.map((m) => [m.user_id, m])), [members])
  // 동아리를 나간 사람은 목록에서 빼고 보여준다 (저장하면 명단에서도 빠진다)
  const picked = value.filter((id) => byId.has(id))
  const over = picked.length > capacity

  return (
    <Field label={`고정 참석자${picked.length ? ` ${picked.length}명` : ''}`} asGroup>
      <p className="text-sm text-ink-soft">
        레슨자처럼 매번 오는 사람은 투표 없이 자동으로 신청돼요. 정원에 포함되고, 못 오는 날은 본인이 취소하면 돼요.
      </p>
      {picked.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {picked.map((id) => (
            <span key={id} className="inline-flex items-center gap-1 rounded-full bg-court-50 py-1 pl-3 pr-1 text-sm font-medium text-court-700">
              {byId.get(id)?.name}
              <button
                type="button"
                aria-label={`${byId.get(id)?.name} 빼기`}
                className="flex h-6 w-6 items-center justify-center rounded-full text-court-700 active:bg-court-100"
                onClick={() => onChange(picked.filter((x) => x !== id))}
              >
                ×
              </button>
            </span>
          ))}
        </div>
      )}
      {over && <p className="mt-2 text-sm font-medium text-danger">고정 참석자가 정원({capacity}명)보다 많아요.</p>}
      <Button type="button" variant="secondary" className="mt-2 w-full" onClick={() => setOpen(true)}>
        {picked.length ? '고정 참석자 바꾸기' : '고정 참석자 고르기'}
      </Button>
      {open && <Picker members={members} initial={picked} onClose={() => setOpen(false)} onDone={(ids) => (onChange(ids), setOpen(false))} />}
    </Field>
  )
}

function Picker({
  members,
  initial,
  onClose,
  onDone,
}: {
  members: MemberOption[]
  initial: string[]
  onClose: () => void
  onDone: (ids: string[]) => void
}) {
  const [sel, setSel] = useState<string[]>(initial)
  const [q, setQ] = useState('')
  const shown = members.filter((m) => !q.trim() || m.name.includes(q.trim()))
  const toggle = (id: string) => setSel((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]))

  return (
    <Sheet title="고정 참석자" onClose={onClose}>
      <div className="p-4">
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="이름 검색" aria-label="이름 검색" className="!mt-0" />
        <ul className="mt-3 max-h-[50vh] divide-y divide-black/[0.05] overflow-y-auto">
          {shown.map((m) => (
            <li key={m.user_id}>
              <label className="flex items-center gap-3 py-2.5">
                <input type="checkbox" checked={sel.includes(m.user_id)} onChange={() => toggle(m.user_id)} className="h-5 w-5 accent-court-600" />
                <span className="font-medium text-ink">{m.name}</span>
                {m.level && <Badge tone="outline">{m.level}</Badge>}
              </label>
            </li>
          ))}
          {shown.length === 0 && <li className="py-6 text-center text-sm text-ink-faint">맞는 회원이 없어요</li>}
        </ul>
        <Button className="mt-4 w-full" onClick={() => onDone(sel)}>
          {sel.length}명 고르기
        </Button>
      </div>
    </Sheet>
  )
}
