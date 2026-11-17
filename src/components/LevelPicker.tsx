/** 급수 목록. DB 제약(club_members_level_choice)과 같아야 한다 */
export const LEVELS = ['A조', 'B조', 'C조', 'D조', '초심'] as const
export type Level = (typeof LEVELS)[number]

/** 급수 고르기 (내 정보). 고른 칸을 다시 누르면 비운다 */
export function LevelPicker({ value, onChange, disabled }: { value: string | null; onChange: (v: Level | null) => void; disabled?: boolean }) {
  return (
    <div role="group" aria-label="급수" className="mt-1.5 grid grid-cols-5 gap-1 rounded-xl bg-black/[0.05] p-0.5">
      {LEVELS.map((lv) => {
        const on = value === lv
        return (
          <button
            key={lv}
            type="button"
            aria-pressed={on}
            disabled={disabled}
            onClick={() => onChange(on ? null : lv)}
            className={`h-11 rounded-[10px] text-[15px] font-semibold disabled:opacity-40 ${on ? 'bg-white text-court-700 shadow-sm' : 'text-ink-soft'}`}
          >
            {lv}
          </button>
        )
      })}
    </div>
  )
}

/** 회원 관리 목록용 작은 선택 상자 */
export function LevelSelect({ value, onChange, disabled, label }: { value: string | null; onChange: (v: Level | null) => void; disabled?: boolean; label: string }) {
  return (
    <select
      aria-label={label}
      value={value ?? ''}
      disabled={disabled}
      onChange={(e) => onChange((e.target.value || null) as Level | null)}
      className={`h-8 shrink-0 rounded-lg border px-1.5 text-[13px] font-semibold disabled:opacity-40 ${value ? 'border-black/10 bg-white text-ink' : 'border-dashed border-black/20 bg-transparent text-ink-faint'}`}
    >
      <option value="">급수</option>
      {LEVELS.map((lv) => (
        <option key={lv} value={lv}>
          {lv}
        </option>
      ))}
    </select>
  )
}
