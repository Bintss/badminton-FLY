import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { ClubLogo } from '../components/ClubLogo'
import { IconChevronRight } from '../components/icons'
import { Empty, List, Page, SectionTitle, Skeleton } from '../components/ui'
import { trimSeconds, WEEKDAYS } from '../lib/datetime'
import { supabase } from '../lib/supabase'
import { linkLabel, mapLink } from '../lib/clubLogo'
import type { ClubPlace, SessionTemplate } from '../lib/types'

/** 동아리 소개: 로고, 소개글, 정기운동, 운동 장소, 연락 링크 */
export default function ClubAboutPage() {
  const { club, isAdmin } = useClub()
  const [places, setPlaces] = useState<ClubPlace[] | null>(null)
  const [templates, setTemplates] = useState<SessionTemplate[]>([])

  useEffect(() => {
    void Promise.all([
      supabase.from('club_places').select('*').eq('club_id', club.id).order('sort').order('created_at'),
      supabase.from('session_templates').select('*').eq('club_id', club.id).eq('active', true).order('weekday').order('start_time'),
    ]).then(([p, t]) => {
      setPlaces((p.data as ClubPlace[] | null) ?? [])
      setTemplates((t.data as SessionTemplate[] | null) ?? [])
    })
  }, [club.id])

  return (
    <Page>
      <div className="flex flex-col items-center pb-2 pt-4 text-center">
        <ClubLogo club={club} size={88} />
        <h1 className="mt-4 text-[24px] font-bold tracking-tight text-ink">{club.name}</h1>
        {club.description ? (
          <p className="mt-3 max-w-sm whitespace-pre-line text-[15px] leading-relaxed text-ink-soft">{club.description}</p>
        ) : (
          isAdmin && <p className="mt-3 text-sm text-ink-faint">아직 소개글이 없어요.</p>
        )}
        {club.link_url && (
          <a
            href={club.link_url}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-4 inline-flex h-11 items-center rounded-xl border border-black/10 bg-white px-4 text-[15px] font-semibold text-court-700 active:bg-floor"
          >
            {linkLabel(club.link_url)}
          </a>
        )}
        {isAdmin && (
          <Link to={`/c/${club.id}/admin/club`} className="mt-3 text-sm font-semibold text-court-600">
            동아리 정보 수정
          </Link>
        )}
      </div>

      {templates.length > 0 && (
        <>
          <SectionTitle>정기운동</SectionTitle>
          <List>
            {templates.map((t) => (
              <div key={t.id} className="flex items-baseline justify-between gap-3 px-4 py-3.5">
                <span className="font-medium text-ink">{t.title}</span>
                <span className="text-sm text-ink-soft">
                  매주 {WEEKDAYS[t.weekday]} {trimSeconds(t.start_time)}~{trimSeconds(t.end_time)}
                </span>
              </div>
            ))}
          </List>
        </>
      )}

      <SectionTitle>운동 장소</SectionTitle>
      {!places ? (
        <Skeleton className="h-16 w-full rounded-2xl" />
      ) : places.length === 0 ? (
        <Empty title="등록된 장소가 없어요">{isAdmin && '동아리 정보 수정에서 자주 가는 체육관을 등록해 두면 번개를 만들 때 고를 수 있어요.'}</Empty>
      ) : (
        <List>
          {places.map((p) => (
            <a key={p.id} href={mapLink(p)} target="_blank" rel="noopener noreferrer" className="flex items-center justify-between gap-3 px-4 py-3.5 active:bg-floor">
              <div className="min-w-0">
                <p className="font-semibold text-ink">{p.name}</p>
                {p.address && <p className="truncate text-sm text-ink-soft">{p.address}</p>}
                {p.note && <p className="text-sm text-ink-faint">{p.note}</p>}
              </div>
              <span className="flex shrink-0 items-center gap-0.5 text-sm font-medium text-court-600">
                지도
                <IconChevronRight className="h-4 w-4" />
              </span>
            </a>
          ))}
        </List>
      )}
    </Page>
  )
}
