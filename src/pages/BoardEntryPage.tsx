import { useEffect, useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { IconChevronRight } from '../components/icons'
import { Empty, List, ListSkeleton, Page } from '../components/ui'
import { DEFAULT_TZ, formatDateTime, formatTime } from '../lib/datetime'
import { serverNow, syncServerClock } from '../lib/serverTime'
import { supabase } from '../lib/supabase'
import type { SessionOverview } from '../lib/types'

const WINDOW_MS = 3 * 3600_000 // 운동 3시간 전 ~ 끝나고 3시간

/** 대진판 탭: 지금 열 수 있는 운동이 하나면 바로 그 대진판으로, 여러 개면 고르게 */
export default function BoardEntryPage() {
  const { club } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const [now, setNow] = useState<SessionOverview[] | null>(null)
  const [next, setNext] = useState<SessionOverview | null>(null)

  useEffect(() => {
    let alive = true
    void (async () => {
      await syncServerClock()
      const t = serverNow()
      const { data } = await supabase
        .from('session_overview')
        .select('*')
        .eq('club_id', club.id)
        .is('canceled_at', null)
        .gt('ends_at', new Date(t - WINDOW_MS).toISOString())
        .order('starts_at')
        .limit(10)
      if (!alive) return
      const rows = (data as SessionOverview[] | null) ?? []
      setNow(rows.filter((s) => Date.parse(s.starts_at) - WINDOW_MS <= t))
      setNext(rows.find((s) => Date.parse(s.starts_at) - WINDOW_MS > t) ?? null)
    })()
    return () => {
      alive = false
    }
  }, [club.id])

  if (!now) return <Page title="대진판"><ListSkeleton rows={2} /></Page>
  if (now.length === 1) return <Navigate to={`/c/${club.id}/s/${now[0].id}/board`} replace />

  return (
    <Page title="대진판">
      {now.length === 0 ? (
        <Empty title="지금 열린 대진판이 없어요">
          대진판은 운동 시작 3시간 전부터 열려요.
          {next && (
            <p className="mt-2">
              다음 운동: {next.title} {formatDateTime(next.starts_at, tz)}
            </p>
          )}
        </Empty>
      ) : (
        <List>
          {now.map((s) => (
            <Link key={s.id} to={`/c/${club.id}/s/${s.id}/board`} className="flex items-center justify-between px-4 py-4 active:bg-floor">
              <div>
                <p className="font-semibold text-ink">{s.title}</p>
                <p className="text-sm text-ink-soft">
                  {formatDateTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}, 코트 {s.court_count}면
                </p>
              </div>
              <IconChevronRight className="h-5 w-5 text-ink-faint" />
            </Link>
          ))}
        </List>
      )}
    </Page>
  )
}
