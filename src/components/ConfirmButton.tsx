import { useEffect, useState, type ReactNode } from 'react'

/** 실수로 누르기 쉬운 버튼: 첫 탭은 확인 상태로, 3초 안에 다시 누르면 실행 */
export function ConfirmButton({
  label,
  confirmLabel,
  onConfirm,
  className = '',
  armedClassName = 'bg-danger text-white',
  disabled,
  ariaLabel,
}: {
  label: ReactNode
  confirmLabel: string
  onConfirm: () => void
  className?: string
  armedClassName?: string
  disabled?: boolean
  ariaLabel?: string
}) {
  const [armed, setArmed] = useState(false)
  useEffect(() => {
    if (!armed) return
    const t = setTimeout(() => setArmed(false), 3000)
    return () => clearTimeout(t)
  }, [armed])
  return (
    <button
      type="button"
      aria-label={armed ? confirmLabel : ariaLabel}
      disabled={disabled}
      className={`inline-flex items-center justify-center rounded-xl font-semibold transition-colors disabled:opacity-40 ${armed ? armedClassName : className}`}
      onClick={(e) => {
        e.stopPropagation()
        if (armed) {
          setArmed(false)
          onConfirm()
        } else setArmed(true)
      }}
    >
      {armed ? confirmLabel : label}
    </button>
  )
}
