import type { ButtonHTMLAttributes, ReactNode } from 'react'

export function Page({ title, children, action }: { title?: string; children: ReactNode; action?: ReactNode }) {
  return (
    <main className="mx-auto min-h-dvh max-w-md px-4 pb-16 pt-4">
      {title && (
        <header className="mb-4 flex items-center justify-between">
          <h1 className="text-xl font-bold text-neutral-900">{title}</h1>
          {action}
        </header>
      )}
      {children}
    </main>
  )
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`rounded-2xl bg-white p-4 shadow-sm ring-1 ring-neutral-200 ${className}`}>{children}</section>
}

type Variant = 'primary' | 'secondary' | 'danger' | 'kakao'
const VARIANTS: Record<Variant, string> = {
  primary: 'bg-neutral-900 text-white active:bg-neutral-700',
  secondary: 'bg-neutral-100 text-neutral-900 active:bg-neutral-200',
  danger: 'bg-red-50 text-red-700 active:bg-red-100',
  kakao: 'bg-[#FEE500] text-[#191919] active:brightness-95',
}

export function Button({
  variant = 'primary',
  className = '',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      className={`h-11 rounded-xl px-4 text-[15px] font-semibold transition disabled:opacity-40 ${VARIANTS[variant]} ${className}`}
      {...props}
    />
  )
}

export function Spinner({ label = '불러오는 중' }: { label?: string }) {
  return <p className="py-10 text-center text-sm text-neutral-500">{label}…</p>
}

export function ErrorText({ children }: { children: ReactNode }) {
  if (!children) return null
  return <p className="mt-2 text-sm text-red-600">{children}</p>
}

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: 'neutral' | 'amber' | 'blue' }) {
  const tones = {
    neutral: 'bg-neutral-100 text-neutral-700',
    amber: 'bg-amber-100 text-amber-800',
    blue: 'bg-blue-100 text-blue-800',
  }
  return <span className={`rounded-md px-1.5 py-0.5 text-xs font-medium ${tones[tone]}`}>{children}</span>
}
