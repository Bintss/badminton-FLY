import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes } from 'react'

const inputClass =
  'mt-1.5 h-12 w-full rounded-xl border border-black/10 bg-white px-3.5 text-[16px] text-ink outline-none transition-colors placeholder:text-ink-faint focus:border-court-500 focus:ring-2 focus:ring-court-100 disabled:bg-floor disabled:text-ink-faint'

export function Field({ label, hint, children }: { label: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <label className="block">
      <span className="text-[13px] font-semibold text-ink-soft">{label}</span>
      {children}
      {hint && <span className="mt-1.5 block text-xs text-ink-faint">{hint}</span>}
    </label>
  )
}

// 글자 크기 16px: iOS에서 입력할 때 화면이 확대되지 않게
export function Input(props: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...props} className={`${inputClass} ${props.className ?? ''}`} />
}

export function Select(props: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select {...props} className={`${inputClass} ${props.className ?? ''}`} />
}

/** 두 개 중 하나 고르기 */
export function Segmented<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T
  options: { value: T; label: string }[]
  onChange: (v: T) => void
}) {
  return (
    <div className="mt-1.5 grid grid-flow-col gap-1 rounded-xl bg-black/[0.05] p-1" role="radiogroup">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          onClick={() => onChange(o.value)}
          className={`h-10 rounded-lg text-[15px] font-semibold transition-colors ${value === o.value ? 'bg-white text-court-700 shadow-sm' : 'text-ink-soft'}`}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}
