import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { Input } from '../components/form'
import { IconChevronRight } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'
import type { Club, MembershipWithClub } from '../lib/types'

export default function ClubsPage() {
  const { session, signOut } = useAuth()
  const navigate = useNavigate()
  const toast = useToast()
  const [memberships, setMemberships] = useState<MembershipWithClub[] | null>(null)
  const [clubs, setClubs] = useState<Club[]>([])
  const [busyId, setBusyId] = useState<string | null>(null)
  const [newName, setNewName] = useState('')

  const uid = session?.user.id

  const load = useCallback(async () => {
    if (!uid) return
    const [mine, all] = await Promise.all([
      supabase.from('club_members').select('*, clubs(id, name)').eq('user_id', uid).order('requested_at'),
      supabase.from('clubs').select('id, name, created_at').order('name'),
    ])
    if (mine.error || all.error) {
      toast.error(errorMessage(mine.error ?? all.error))
      return
    }
    setMemberships(mine.data as MembershipWithClub[])
    setClubs(all.data as Club[])
  }, [uid, toast])

  useEffect(() => {
    void load()
  }, [load])

  const requestJoin = async (clubId: string) => {
    setBusyId(clubId)
    const { error } = await supabase.rpc('request_join', { p_club: clubId })
    if (error) toast.error(errorMessage(error))
    else toast.success('가입을 신청했어요. 운영진이 승인하면 들어갈 수 있어요.')
    await load()
    setBusyId(null)
  }

  const createClub = async (e: FormEvent) => {
    e.preventDefault()
    if (!newName.trim()) return
    setBusyId('new')
    const { data, error } = await supabase.rpc('create_club', { p_name: newName.trim() })
    setBusyId(null)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    toast.success('동아리를 만들었어요')
    navigate(`/c/${data as string}`)
  }

  const signOutButton = (
    <button className="text-sm font-medium text-ink-soft" onClick={() => void signOut()}>
      로그아웃
    </button>
  )

  if (!memberships) return <Page title="동아리" action={signOutButton}><ListSkeleton rows={2} /></Page>

  const visibleMine = memberships.filter((m) => m.status !== 'left')
  const mineIds = new Set(visibleMine.map((m) => m.club_id))
  const others = clubs.filter((c) => !mineIds.has(c.id))

  return (
    <Page title="동아리" action={signOutButton}>
      {visibleMine.length === 0 ? (
        <Empty title="아직 가입한 동아리가 없어요">아래 목록에서 가입을 신청하거나 새 동아리를 만들어 보세요.</Empty>
      ) : (
        <List>
          {visibleMine.map((m) =>
            m.status === 'approved' ? (
              <Link key={m.club_id} to={`/c/${m.club_id}`} className="flex items-center justify-between gap-3 px-4 py-4 active:bg-floor">
                <div className="min-w-0">
                  <p className="truncate font-semibold text-ink">{m.clubs?.name ?? '동아리'}</p>
                  <p className="text-sm text-ink-soft">{m.role === 'admin' ? '운영진' : '회원'}</p>
                </div>
                <IconChevronRight className="h-5 w-5 shrink-0 text-ink-faint" />
              </Link>
            ) : (
              <div key={m.club_id} className="flex items-center justify-between gap-3 px-4 py-4">
                <div className="min-w-0">
                  <p className="truncate font-semibold text-ink">{m.clubs?.name ?? '동아리'}</p>
                  <div className="mt-1">
                    {m.status === 'pending' ? <Badge tone="shuttle">승인 기다리는 중</Badge> : <Badge>거절됨</Badge>}
                  </div>
                </div>
                {m.status === 'pending' ? (
                  <Button variant="ghost" className="h-10" onClick={() => void load()}>
                    새로고침
                  </Button>
                ) : (
                  <Button variant="secondary" className="h-10" disabled={busyId === m.club_id} onClick={() => void requestJoin(m.club_id)}>
                    다시 신청
                  </Button>
                )}
              </div>
            ),
          )}
        </List>
      )}

      {others.length > 0 && (
        <>
          <SectionTitle>다른 동아리</SectionTitle>
          <List>
            {others.map((c) => (
              <div key={c.id} className="flex items-center justify-between gap-3 px-4 py-3">
                <p className="truncate font-medium text-ink">{c.name}</p>
                <Button variant="secondary" className="h-10" disabled={busyId === c.id} onClick={() => void requestJoin(c.id)}>
                  가입 신청
                </Button>
              </div>
            ))}
          </List>
        </>
      )}

      <SectionTitle>새 동아리 만들기</SectionTitle>
      <Card>
        <form onSubmit={createClub} className="flex gap-2">
          <Input value={newName} onChange={(e) => setNewName(e.target.value)} maxLength={50} placeholder="동아리 이름" className="mt-0 min-w-0 flex-1" />
          <Button type="submit" disabled={busyId === 'new' || !newName.trim()}>
            만들기
          </Button>
        </form>
        <p className="mt-2 text-xs text-ink-faint">만든 사람이 첫 운영진이 돼요.</p>
      </Card>
    </Page>
  )
}
