import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { ClubPlace } from '../lib/types'
import { Input } from './form'

/** 장소 입력: 동아리에 등록된 장소를 버튼으로 한 번에 고르거나 직접 입력 */
export function PlaceInput({ clubId, value, onChange }: { clubId: string; value: string; onChange: (v: string) => void }) {
  const [places, setPlaces] = useState<ClubPlace[]>([])

  useEffect(() => {
    supabase
      .from('club_places')
      .select('*')
      .eq('club_id', clubId)
      .order('sort')
      .order('created_at')
      .then(({ data }) => setPlaces((data as ClubPlace[] | null) ?? []))
  }, [clubId])

  return (
    <>
      {places.length > 0 && (
        <div className="mt-1.5 flex flex-wrap gap-1.5" role="group" aria-label="등록된 장소">
          {places.map((p) => {
            const on = value === p.name
            return (
              <button
                key={p.id}
                type="button"
                onClick={() => onChange(on ? '' : p.name)}
                aria-pressed={on}
                className={`h-9 rounded-full px-3.5 text-sm font-semibold transition-colors ${on ? 'bg-court-600 text-white' : 'border border-black/10 bg-white text-ink-soft active:bg-floor'}`}
              >
                {p.name}
              </button>
            )
          })}
        </div>
      )}
      <Input value={value} onChange={(e) => onChange(e.target.value)} placeholder={places.length > 0 ? '또는 직접 입력' : '예: 학교 체육관'} maxLength={100} />
    </>
  )
}
