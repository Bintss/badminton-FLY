import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes, TextareaHTMLAttributes } from 'react'

const inputClass =
  'mt-1.5 h-12 w-full rounded-xl border border-black/10 bg-white px-3.5 text-[16px] text-ink outline-none transition-colors placeholder:text-ink-faint focus:border-court-500 focus:ring-2 focus:ring-court-100 disabled:bg-floor disabled:text-ink-faint'

export function Field({ label, hint, children, asGroup = false }: { label: string; hint?: ReactNode; children: ReactNode; asGroup?: boolean }) {
  // 버튼이 여러 개 들어가는 입력(장소 선택 등)은 <label> 대신 group으로 감싼다
  const Tag = asGroup ? 'div' : 'label'
  return (
    <Tag className="block" {...(asGroup ? { role: 'group', 'aria-label': label } : {})}>
      <span className="text-[13px] font-semibold text-ink-soft">{label}</span>
      {children}
      {hint && <span className="mt-1.5 block text-xs text-ink-faint">{hint}</span>}
    </Tag>
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

export function Textarea(props: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      {...props}
      className={`mt-1.5 min-h-28 w-full rounded-xl border border-black/10 bg-white px-3.5 py-3 text-[16px] leading-relaxed text-ink outline-none transition-colors placeholder:text-ink-faint focus:border-court-500 focus:ring-2 focus:ring-court-100 ${props.className ?? ''}`}
    />
  )
}
