import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { ClubLogo } from '../components/ClubLogo'
import { Field, Input, Textarea } from '../components/form'
import { IconChevronLeft, IconPlus } from '../components/icons'
import { useToast } from '../components/toast'
import { Button, Card, Empty, List, Page, SectionTitle } from '../components/ui'
import { LOGO_BUCKET, uploadClubLogo } from '../lib/clubLogo'
import { errorMessage, supabase } from '../lib/supabase'
import type { ClubPlace } from '../lib/types'

type PlaceDraft = { id: string | null; name: string; address: string; note: string }

export default function ClubEditPage() {
  const { club, isAdmin, reload } = useClub()
  const toast = useToast()

  const [name, setName] = useState(club.name)
  const [description, setDescription] = useState(club.description ?? '')
  const [link, setLink] = useState(club.link_url ?? '')
  const [busy, setBusy] = useState(false)
  const [logoBusy, setLogoBusy] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  const [places, setPlaces] = useState<ClubPlace[]>([])
  const [draft, setDraft] = useState<PlaceDraft | null>(null)

  const loadPlaces = useCallback(async () => {
    const { data } = await supabase.from('club_places').select('*').eq('club_id', club.id).order('sort').order('created_at')
    setPlaces((data as ClubPlace[] | null) ?? [])
  }, [club.id])

  useEffect(() => {
    void loadPlaces()
  }, [loadPlaces])

  if (!isAdmin) return <Navigate to={`/c/${club.id}/about`} replace />

  const dirty = name.trim() !== club.name || description !== (club.description ?? '') || link.trim() !== (club.link_url ?? '')

  const saveProfile = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    const { error } = await supabase.rpc('update_club_profile', {
      p_club: club.id,
      p_name: name,
      p_description: description,
      p_link_url: link,
    })
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    await reload()
    toast.success('동아리 정보를 저장했어요')
  }

  const changeLogo = async (file: File | undefined) => {
    if (!file) return
    if (!file.type.startsWith('image/')) {
      toast.error('이미지 파일을 골라주세요')
      return
    }
    setLogoBusy(true)
    try {
      const old = club.logo_path
      const path = await uploadClubLogo(club.id, file)
      const { error } = await supabase.rpc('set_club_logo', { p_club: club.id, p_logo_path: path })
      if (error) throw error
      if (old) void supabase.storage.from(LOGO_BUCKET).remove([old]) // 이전 파일 정리 (실패해도 무시)
      await reload()
      toast.success('로고를 바꿨어요')
    } catch (err) {
      toast.error(errorMessage(err))
    } finally {
      setLogoBusy(false)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  const removeLogo = async () => {
    if (!club.logo_path) return
    setLogoBusy(true)
    const old = club.logo_path
    const { error } = await supabase.rpc('set_club_logo', { p_club: club.id, p_logo_path: null })
    setLogoBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    void supabase.storage.from(LOGO_BUCKET).remove([old])
    await reload()
    toast.info('로고를 지웠어요')
  }

  const savePlace = async (e: FormEvent) => {
    e.preventDefault()
    if (!draft || !draft.name.trim()) return
    setBusy(true)
    const { error } = await supabase.rpc('save_place', {
      p_club: club.id,
      p_id: draft.id,
      p_name: draft.name,
      p_address: draft.address,
      p_note: draft.note,
    })
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    toast.success(draft.id ? '장소를 수정했어요' : `${draft.name.trim()}을(를) 추가했어요`)
    setDraft(null)
    await loadPlaces()
  }

  const deletePlace = async (p: ClubPlace) => {
    setBusy(true)
    const { error } = await supabase.rpc('delete_place', { p_place: p.id })
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else toast.info(`${p.name}을(를) 지웠어요`)
    setDraft(null)
    await loadPlaces()
  }

  return (
    <Page
      title="동아리 정보 수정"
      back={
        <Link to={`/c/${club.id}/about`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
          <IconChevronLeft className="h-4 w-4" />
          동아리 소개
        </Link>
      }
    >
      {/* 로고 */}
      <Card className="flex items-center gap-4">
        <ClubLogo club={club} size={72} />
        <div className="min-w-0 flex-1">
          <p className="font-semibold text-ink">로고</p>
          <p className="text-xs text-ink-faint">정사각형으로 잘라서 올려요. 가운데 기준이에요.</p>
          <div className="mt-2 flex gap-2">
            <Button variant="secondary" className="h-10" disabled={logoBusy} onClick={() => fileRef.current?.click()}>
              {logoBusy ? '올리는 중' : club.logo_path ? '바꾸기' : '올리기'}
            </Button>
            {club.logo_path && (
              <Button variant="ghost" className="h-10 text-danger" disabled={logoBusy} onClick={() => void removeLogo()}>
                지우기
              </Button>
            )}
          </div>
          <input ref={fileRef} type="file" accept="image/png,image/jpeg,image/webp" className="hidden" onChange={(e) => void changeLogo(e.target.files?.[0])} />
        </div>
      </Card>

      {/* 기본 정보 */}
      <Card className="mt-3">
        <form onSubmit={saveProfile} className="space-y-4">
          <Field label="동아리 이름">
            <Input value={name} onChange={(e) => setName(e.target.value)} maxLength={50} required />
          </Field>
          <Field label="소개" hint={`${description.length}/1000 · 가입 전에도 보여요. 운동 요일, 회비, 대상 등을 적어두면 좋아요.`}>
            <Textarea value={description} onChange={(e) => setDescription(e.target.value)} maxLength={1000} placeholder="예: 단국대 배드민턴 동아리예요. 수·토 저녁에 죽전 체육관에서 운동해요. 초보도 환영해요." />
          </Field>
          <Field label="연락 링크" hint="오픈채팅, 인스타그램 등. https://로 시작해야 해요.">
            <Input type="url" inputMode="url" value={link} onChange={(e) => setLink(e.target.value)} placeholder="https://open.kakao.com/o/..." />
          </Field>
          <Button type="submit" className="w-full" disabled={busy || !dirty || !name.trim()}>
            저장
          </Button>
        </form>
      </Card>

      {/* 운동 장소 */}
      <SectionTitle
        right={
          !draft && (
            <button className="inline-flex items-center gap-0.5 text-sm font-semibold text-court-600" onClick={() => setDraft({ id: null, name: '', address: '', note: '' })}>
              <IconPlus className="h-4 w-4" />
              장소 추가
            </button>
          )
        }
      >
        운동 장소
      </SectionTitle>

      {draft && (
        <Card className="mb-3">
          <form onSubmit={savePlace} className="space-y-3">
            <Field label="이름">
              <Input value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} maxLength={50} placeholder="예: 단국대 체육관" required autoFocus />
            </Field>
            <Field label="주소" hint="지도 검색에 쓰여요.">
              <Input value={draft.address} onChange={(e) => setDraft({ ...draft, address: e.target.value })} maxLength={200} placeholder="예: 경기 용인시 수지구 죽전로 152" />
            </Field>
            <Field label="메모">
              <Input value={draft.note} onChange={(e) => setDraft({ ...draft, note: e.target.value })} maxLength={200} placeholder="예: 2층, 실내화 필수" />
            </Field>
            <div className="flex gap-2 pt-1">
              {draft.id && (
                <Button
                  type="button"
                  variant="ghost"
                  className="text-danger"
                  disabled={busy}
                  onClick={() => {
                    const p = places.find((x) => x.id === draft.id)
                    if (p) void deletePlace(p)
                  }}
                >
                  삭제
                </Button>
              )}
              <Button type="button" variant="secondary" className="flex-1" onClick={() => setDraft(null)}>
                취소
              </Button>
              <Button type="submit" className="flex-1" disabled={busy || !draft.name.trim()}>
                저장
              </Button>
            </div>
          </form>
        </Card>
      )}

      {places.length === 0 && !draft ? (
        <Empty title="등록된 장소가 없어요">자주 가는 체육관을 등록하면 번개를 만들거나 정기운동을 등록할 때 고를 수 있어요.</Empty>
      ) : (
        places.length > 0 && (
          <List>
            {places.map((p) => (
              <button key={p.id} className="flex w-full items-center justify-between gap-3 px-4 py-3.5 text-left active:bg-floor" onClick={() => setDraft({ id: p.id, name: p.name, address: p.address, note: p.note })}>
                <div className="min-w-0">
                  <p className="font-semibold text-ink">{p.name}</p>
                  {(p.address || p.note) && <p className="truncate text-sm text-ink-soft">{[p.address, p.note].filter(Boolean).join(', ')}</p>}
                </div>
                <span className="shrink-0 text-sm font-medium text-court-600">수정</span>
              </button>
            ))}
          </List>
        )
      )}
    </Page>
  )
}
