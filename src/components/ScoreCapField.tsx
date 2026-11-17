import { Field, Input } from './form'

/** 최대 점수: 있음/없음 + 점수 (자체대회 만들기·대회 설정) */
export function ScoreCapField({ capOn, setCapOn, cap, setCap }: { capOn: boolean; setCapOn: (v: boolean) => void; cap: string; setCap: (v: string) => void }) {
  return (
    <Field label="최대 점수" asGroup>
      <div className="mt-1.5 flex items-center gap-2">
        <button
          type="button"
          aria-pressed={capOn}
          onClick={() => setCapOn(!capOn)}
          className={`h-12 shrink-0 rounded-xl px-3 text-[14px] font-semibold ${capOn ? 'bg-court-50 text-court-700' : 'border border-black/10 bg-white text-ink-soft'}`}
        >
          {capOn ? '있음' : '없음'}
        </button>
        {capOn && <Input aria-label="최대 점수" className="!mt-0" type="number" inputMode="numeric" min={5} max={60} value={cap} onChange={(e) => setCap(e.target.value)} />}
      </div>
    </Field>
  )
}
