// 날짜·시각 표시와 변환. 동아리 시간대(기본 Asia/Seoul) 기준으로 다룬다.

export const DEFAULT_TZ = 'Asia/Seoul'
export const WEEKDAYS = ['일', '월', '화', '수', '목', '금', '토'] as const

function parts(date: Date, tz: string) {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
    weekday: 'short',
  })
  const map: Record<string, string> = {}
  for (const p of fmt.formatToParts(date)) map[p.type] = p.value
  const wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(map.weekday)
  return {
    y: Number(map.year),
    m: Number(map.month),
    d: Number(map.day),
    hh: map.hour,
    mm: map.minute,
    wd,
  }
}

/** "11/18(수) 19:00" */
export function formatDateTime(iso: string | number, tz = DEFAULT_TZ): string {
  const p = parts(new Date(iso), tz)
  return `${p.m}/${p.d}(${WEEKDAYS[p.wd]}) ${p.hh}:${p.mm}`
}

/** "19:00" */
export function formatTime(iso: string | number, tz = DEFAULT_TZ): string {
  const p = parts(new Date(iso), tz)
  return `${p.hh}:${p.mm}`
}

/** "2026-11-18" (동아리 시간대 기준 날짜, <input type=date> 값) */
export function toDateInput(iso: string | number, tz = DEFAULT_TZ): string {
  const p = parts(new Date(iso), tz)
  return `${p.y}-${String(p.m).padStart(2, '0')}-${String(p.d).padStart(2, '0')}`
}

/** "19:00" (<input type=time> 값) */
export function toTimeInput(iso: string | number, tz = DEFAULT_TZ): string {
  return formatTime(iso, tz)
}

/**
 * 동아리 시간대의 "날짜 + 시각"을 UTC ISO 문자열로 바꾼다.
 * 단말 시간대와 무관하게 동작한다 (해외에서 접속해도 동아리 시각 기준).
 */
export function zonedToIso(date: string, time: string, tz = DEFAULT_TZ): string {
  const [y, m, d] = date.split('-').map(Number)
  const [hh, mm] = time.split(':').map(Number)
  const guess = Date.UTC(y, m - 1, d, hh, mm)
  // guess를 tz로 표시했을 때의 벽시계와 원하는 벽시계의 차이만큼 보정
  const p = parts(new Date(guess), tz)
  const shown = Date.UTC(p.y, p.m - 1, p.d, Number(p.hh), Number(p.mm))
  return new Date(guess - (shown - guess)).toISOString()
}

/** 'HH:MM:SS' → 'HH:MM' */
export function trimSeconds(t: string): string {
  return t.slice(0, 5)
}
