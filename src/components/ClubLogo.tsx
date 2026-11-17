import { useState } from 'react'
import { logoUrl } from '../lib/clubLogo'
import type { Club } from '../lib/types'

/** 동아리 로고. 없거나 못 불러오면 이름 첫 글자 */
export function ClubLogo({ club, size = 40, className = '' }: { club: Pick<Club, 'name' | 'logo_path'>; size?: number; className?: string }) {
  const [failed, setFailed] = useState(false)
  const url = club.logo_path && !failed ? logoUrl(club.logo_path) : null
  const radius = Math.round(size * 0.28)
  const style = { width: size, height: size, borderRadius: radius }

  if (url) {
    return <img src={url} alt="" style={style} className={`shrink-0 border border-black/[0.06] bg-white object-cover ${className}`} onError={() => setFailed(true)} />
  }
  return (
    <span
      aria-hidden
      style={{ ...style, fontSize: Math.round(size * 0.45) }}
      className={`flex shrink-0 items-center justify-center bg-court-600 font-bold text-white ${className}`}
    >
      {club.name.trim().charAt(0) || '?'}
    </span>
  )
}
