import { useState } from 'react'
import { scoreProblem } from '../lib/tournament'
import { Sheet } from './Sheet'
import { Button } from './ui'

export type ScoreKind = 'normal' | 'walkover1' | 'walkover2' | 'clear' | null

/**
 * 대회 경기 점수 입력 창
 *   finish: 경기 종료와 함께 (점수 없이 종료 = 나중에 입력)
 *   edit:   끝난 경기 점수 입력·수정
 *   onSubmit이 오류 문구를 돌려주면 창을 닫지 않고 보여준다
 */
export function ScoreSheet({
  mode,
  title,
  team1,
  team2,
  target,
  cap,
  initial,
  canScore,
  canClear,
  onSubmit,
  onClose,
}: {
  mode: 'finish' | 'edit'
  title: string
  team1: string
  team2: string
  target: number
  cap: number | null
  initial?: { score1: number | null; score2: number | null }
  canScore: boolean
  canClear?: boolean
  onSubmit: (kind: ScoreKind, s1: number | null, s2: number | null) => Promise<string | null>
  onClose: () => void
}) {
  const [s1, setS1] = useState(initial?.score1 != null ? String(initial.score1) : '')
  const [s2, setS2] = useState(initial?.score2 != null ? String(initial.score2) : '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [walkover, setWalkover] = useState(false)

  const n1 = s1 === '' ? null : Number(s1)
  const n2 = s2 === '' ? null : Number(s2)
  const problem = s1 === '' && s2 === '' ? null : scoreProblem(target, cap, n1, n2)
  const ready = s1 !== '' && s2 !== '' && !problem

  const submit = async (kind: ScoreKind, a: number | null, b: number | null) => {
    setBusy(true)
    setError('')
    const err = await onSubmit(kind, a, b)
    setBusy(false)
    if (err) setError(err)
    else onClose()
  }

  const step = (set: (v: string) => void, v: string, d: number) => set(String(Math.max(0, Math.min(99, (v === '' ? 0 : Number(v)) + d))))
  // 상대 점수를 보고 이기는 점수를 넣는다: 목표 점수, 듀스면 상대+2, 최대 점수를 넘지 않게
  const quickWin = (team: 1 | 2) => {
    const other = (team === 1 ? n2 : n1) ?? 0
    let w = Math.max(target, other + 2)
    if (cap !== null && w > cap) w = cap
    ;(team === 1 ? setS1 : setS2)(String(w))
  }

  const side = (label: string, value: string, set: (v: string) => void, team: 1 | 2) => (
    <div className="min-w-0 flex-1 text-center">
      <p className="min-h-10 text-[14px] font-semibold leading-snug text-ink">{label}</p>
      <div className="mt-2 flex items-center justify-center gap-1">
        <button type="button" aria-label={`${team}팀 1점 빼기`} onClick={() => step(set, value, -1)} className="h-12 w-10 rounded-xl bg-floor text-xl font-bold text-ink-soft active:bg-black/10">
          −
        </button>
        <input
          inputMode="numeric"
          aria-label={`${team}팀 점수`}
          value={value}
          onChange={(e) => set(e.target.value.replace(/\D/g, '').slice(0, 2))}
          className="score h-16 w-16 rounded-xl border border-black/10 bg-white text-center text-[34px] font-semibold text-ink outline-none focus:border-court-500"
        />
        <button type="button" aria-label={`${team}팀 1점 더하기`} onClick={() => step(set, value, 1)} className="h-12 w-10 rounded-xl bg-floor text-xl font-bold text-ink-soft active:bg-black/10">
          +
        </button>
      </div>
      <button type="button" onClick={() => quickWin(team)} className="mt-2 h-8 rounded-lg px-2 text-xs font-semibold text-court-600 active:bg-court-50">
        승리 점수 넣기
      </button>
    </div>
  )

  return (
    <Sheet title={title} onClose={onClose}>
      <div className="p-4">
        {!canScore ? (
          <p className="rounded-xl bg-floor px-3 py-3 text-sm leading-relaxed text-ink-soft">
            점수는 이 경기 선수나 운영진만 넣을 수 있어요.{mode === 'finish' && ' 코트는 지금 비우고, 점수는 선수가 대진표에서 나중에 넣으면 돼요.'}
          </p>
        ) : walkover ? (
          <div className="space-y-2">
            <p className="text-sm text-ink-soft">기권한 팀의 상대가 이긴 것으로 기록돼요. 점수는 남지 않아요.</p>
            <Button variant="secondary" className="w-full" disabled={busy} onClick={() => void submit('walkover1', null, null)}>
              {team1} 기권승
            </Button>
            <Button variant="secondary" className="w-full" disabled={busy} onClick={() => void submit('walkover2', null, null)}>
              {team2} 기권승
            </Button>
            <button type="button" onClick={() => setWalkover(false)} className="h-10 w-full text-sm font-medium text-ink-soft">
              점수 입력으로 돌아가기
            </button>
          </div>
        ) : (
          <>
            <div className="flex items-start gap-2">
              {side(team1, s1, setS1, 1)}
              <span className="mt-[4.25rem] text-lg font-bold text-ink-faint">:</span>
              {side(team2, s2, setS2, 2)}
            </div>
            <p className={`mt-3 min-h-5 text-center text-sm ${problem ? 'text-danger' : 'text-ink-faint'}`}>
              {problem ?? `${target}점제${cap ? `, 최대 ${cap}점` : ''}`}
            </p>
          </>
        )}

        {error && <p className="mt-2 rounded-lg bg-danger/10 px-3 py-2 text-sm text-danger">{error}</p>}

        {!walkover && (
          <div className="mt-4 space-y-2">
            {canScore && (
              <Button className="h-14 w-full text-[16px]" disabled={busy || !ready} onClick={() => void submit('normal', n1, n2)}>
                {mode === 'finish' ? '점수 저장하고 경기 종료' : '점수 저장'}
              </Button>
            )}
            {mode === 'finish' && (
              <Button variant="secondary" className="w-full" disabled={busy} onClick={() => void submit(null, null, null)}>
                점수 없이 경기 종료 (나중에 입력)
              </Button>
            )}
            {canScore && (
              <div className="flex justify-center gap-4 pt-1">
                <button type="button" onClick={() => setWalkover(true)} className="h-9 text-sm font-medium text-ink-soft underline underline-offset-4">
                  기권으로 기록
                </button>
                {canClear && (
                  <button type="button" disabled={busy} onClick={() => void submit('clear', null, null)} className="h-9 text-sm font-medium text-danger underline underline-offset-4">
                    점수 지우기
                  </button>
                )}
              </div>
            )}
          </div>
        )}
      </div>
    </Sheet>
  )
}
