// 탭·버튼용 단색 아이콘 (currentColor)
type P = { className?: string }
const base = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const }

export function IconCalendar({ className = 'h-6 w-6' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <rect x="3.5" y="5" width="17" height="15" rx="2.5" />
      <path d="M3.5 10h17M8 3v4M16 3v4" />
    </svg>
  )
}

/** 코트를 위에서 본 모양 */
export function IconCourt({ className = 'h-6 w-6' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <rect x="4" y="3" width="16" height="18" rx="1.5" />
      <path d="M4 12h16M12 3v6.5M12 14.5V21M4 9.5h16M4 14.5h16" />
    </svg>
  )
}

export function IconPerson({ className = 'h-6 w-6' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <circle cx="12" cy="8.5" r="3.8" />
      <path d="M4.5 20.5c1.2-3.6 4-5.5 7.5-5.5s6.3 1.9 7.5 5.5" />
    </svg>
  )
}

export function IconChevronLeft({ className = 'h-5 w-5' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <path d="M15 5l-7 7 7 7" />
    </svg>
  )
}

export function IconChevronRight({ className = 'h-5 w-5' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <path d="M9 5l7 7-7 7" />
    </svg>
  )
}

export function IconChevronDown({ className = 'h-5 w-5' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <path d="M5 9l7 7 7-7" />
    </svg>
  )
}

export function IconPlus({ className = 'h-5 w-5' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base} strokeWidth={2.2}>
      <path d="M12 5v14M5 12h14" />
    </svg>
  )
}

export function IconUp({ className = 'h-4 w-4' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base} strokeWidth={2.2}>
      <path d="M6 15l6-6 6 6" />
    </svg>
  )
}

export function IconDown({ className = 'h-4 w-4' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base} strokeWidth={2.2}>
      <path d="M6 9l6 6 6-6" />
    </svg>
  )
}

export function IconX({ className = 'h-4 w-4' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base} strokeWidth={2.2}>
      <path d="M6 6l12 12M18 6L6 18" />
    </svg>
  )
}

export function IconUndo({ className = 'h-4 w-4' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <path d="M9 14L4 9l5-5" />
      <path d="M4 9h10a6 6 0 010 12h-3" />
    </svg>
  )
}

export function IconSun({ className = 'h-4 w-4' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
    </svg>
  )
}

export function IconBell({ className = 'h-6 w-6' }: P) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden {...base}>
      <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z" />
      <path d="M10 20.5a2 2 0 0 0 4 0" />
    </svg>
  )
}
