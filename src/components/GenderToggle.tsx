import type { Gender } from '../lib/autoDraft'

/** 남/여 두 칸 버튼. 고른 쪽을 다시 누르면 비운다 (allowClear) */
export function GenderToggle({
  value,
  onChange,
  disabled,
  compact,
  allowClear = true,
  label = '성별',
}: {
  value: Gender | null
  onChange: (g: Gender | null) => void
  disabled?: boolean
  compact?: boolean
  allowClear?: boolean
  label?: string
}) {
  return (
    <div role="group" aria-label={label} className={`inline-flex shrink-0 rounded-xl bg-black/[0.05] p-0.5 ${compact ? '' : 'mt-1.5'}`}>
      {(['M', 'F'] as const).map((g) => {
        const on = value === g
        return (
          <button
            key={g}
            type="button"
            aria-pressed={on}
            disabled={disabled}
            onClick={() => onChange(on ? (allowClear ? null : g) : g)}
            className={`${compact ? 'h-8 w-9 text-[13px]' : 'h-11 w-16 text-[15px]'} rounded-[10px] font-semibold disabled:opacity-40 ${
              on ? (g === 'M' ? 'bg-white text-sky-700 shadow-sm' : 'bg-white text-rose-600 shadow-sm') : 'text-ink-faint'
            }`}
          >
            {g === 'M' ? '남' : '여'}
          </button>
        )
      })}
    </div>
  )
}

/** 이름 옆 작은 성별 표시 */
export function GenderMark({ g, className = '' }: { g: Gender | null | undefined; className?: string }) {
  if (!g) return null
  return (
    <span className={`text-[11px] font-bold ${g === 'M' ? 'text-sky-700' : 'text-rose-600'} ${className}`} aria-label={g === 'M' ? '남' : '여'}>
      {g === 'M' ? '남' : '여'}
    </span>
  )
}
