import type { ButtonHTMLAttributes, ReactNode } from 'react'

/** 화면 틀. 하단 탭이 있는 화면은 탭에 가리지 않도록 아래 여백을 둔다 */
export function Page({
  title,
  children,
  action,
  back,
  wide = false,
}: {
  title?: ReactNode
  children: ReactNode
  action?: ReactNode
  back?: ReactNode
  wide?: boolean
}) {
  return (
    <main className={`mx-auto min-h-dvh px-4 pb-28 pt-4 ${wide ? 'max-w-4xl' : 'max-w-md'}`}>
      {back && <div className="mb-2">{back}</div>}
      {title && (
        <header className="mb-4 flex items-center justify-between gap-3">
          <h1 className="text-[22px] font-bold tracking-tight text-ink">{title}</h1>
          {action}
        </header>
      )}
      {children}
    </main>
  )
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`rounded-2xl border border-black/[0.06] bg-white p-4 ${className}`}>{children}</section>
}

/** 목록 묶음: 행 사이에만 구분선 */
export function List({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <div className={`divide-y divide-black/[0.06] overflow-hidden rounded-2xl border border-black/[0.06] bg-white ${className}`}>{children}</div>
}

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'kakao'
const VARIANTS: Record<Variant, string> = {
  primary: 'bg-court-600 text-white active:bg-court-700 disabled:bg-court-200',
  secondary: 'border border-black/10 bg-white text-ink active:bg-floor',
  ghost: 'text-ink-soft active:bg-black/5',
  danger: 'bg-danger/10 text-danger active:bg-danger/20',
  kakao: 'bg-[#FEE500] text-[#191919] active:brightness-95',
}

export function Button({
  variant = 'primary',
  className = '',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      className={`inline-flex h-12 items-center justify-center gap-1.5 rounded-xl px-4 text-[15px] font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${VARIANTS[variant]} ${className}`}
      {...props}
    />
  )
}

export function ErrorText({ children }: { children: ReactNode }) {
  if (!children) return null
  return (
    <p role="alert" className="mt-2 text-sm text-danger">
      {children}
    </p>
  )
}

type Tone = 'neutral' | 'court' | 'shuttle' | 'danger' | 'outline'
const TONES: Record<Tone, string> = {
  neutral: 'bg-black/[0.05] text-ink-soft',
  court: 'bg-court-50 text-court-700',
  shuttle: 'bg-shuttle-100 text-shuttle-800',
  danger: 'bg-danger/10 text-danger',
  outline: 'border border-black/10 text-ink-soft',
}

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: Tone }) {
  return <span className={`inline-flex shrink-0 items-center rounded-md px-1.5 py-0.5 text-xs font-semibold ${TONES[tone]}`}>{children}</span>
}

/** 회색으로 반짝이는 자리표시 */
export function Skeleton({ className = '' }: { className?: string }) {
  return <div aria-hidden className={`skeleton rounded-lg ${className}`} />
}

/** 목록 화면용 로딩 자리표시 */
export function ListSkeleton({ rows = 3 }: { rows?: number }) {
  return (
    <div className="space-y-2" aria-label="불러오는 중">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex gap-3 rounded-2xl border border-black/[0.06] bg-white p-4">
          <Skeleton className="h-14 w-12" />
          <div className="flex-1 space-y-2 py-1">
            <Skeleton className="h-4 w-2/3" />
            <Skeleton className="h-3 w-1/2" />
          </div>
        </div>
      ))}
    </div>
  )
}

/** 전체 화면 로딩 (라우트 가드 등) */
export function Spinner({ label = '불러오는 중' }: { label?: string }) {
  return (
    <div className="flex justify-center py-16" role="status" aria-label={label}>
      <span className="h-6 w-6 animate-spin rounded-full border-2 border-court-200 border-t-court-600 motion-reduce:animate-none" />
    </div>
  )
}

/** 빈 화면: 다음 행동을 알려준다 */
export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="rounded-2xl border border-dashed border-black/15 px-5 py-8 text-center">
      <p className="font-semibold text-ink">{title}</p>
      {children && <div className="mt-1 text-sm text-ink-soft">{children}</div>}
    </div>
  )
}

export function SectionTitle({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="mb-2 mt-6 flex items-baseline justify-between">
      <h2 className="text-[15px] font-bold text-ink">{children}</h2>
      {right && <span className="text-sm text-ink-faint">{right}</span>}
    </div>
  )
}
