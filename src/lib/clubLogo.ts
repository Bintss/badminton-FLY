import { supabase } from './supabase'

export const LOGO_BUCKET = 'club-logos'

/** Storage 경로 → 공개 URL */
export function logoUrl(path: string): string {
  return supabase.storage.from(LOGO_BUCKET).getPublicUrl(path).data.publicUrl
}

/**
 * 고른 이미지를 가운데 기준 정사각형으로 자르고 512px로 줄인다.
 * 폰 사진(수 MB)을 그대로 올리지 않도록. webp를 못 만드는 브라우저는 png
 */
export async function squareImage(file: File, size = 512): Promise<Blob> {
  const bitmap = await createImageBitmap(file)
  const side = Math.min(bitmap.width, bitmap.height)
  const sx = (bitmap.width - side) / 2
  const sy = (bitmap.height - side) / 2
  const target = Math.min(size, side)

  const canvas = document.createElement('canvas')
  canvas.width = target
  canvas.height = target
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('canvas_unavailable')
  ctx.fillStyle = '#ffffff' // 투명 PNG 로고도 흰 바탕으로
  ctx.fillRect(0, 0, target, target)
  ctx.drawImage(bitmap, sx, sy, side, side, 0, 0, target, target)
  bitmap.close()

  const toBlob = (type: string, quality?: number) =>
    new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, type, quality))
  const webp = await toBlob('image/webp', 0.9)
  if (webp && webp.type === 'image/webp') return webp
  const png = await toBlob('image/png')
  if (!png) throw new Error('encode_failed')
  return png
}

/** 동아리 로고 업로드: 새 파일 이름으로 올려서 브라우저 캐시 문제를 피한다 */
export async function uploadClubLogo(clubId: string, file: File): Promise<string> {
  const blob = await squareImage(file)
  const ext = blob.type === 'image/webp' ? 'webp' : 'png'
  const path = `${clubId}/logo-${Date.now()}.${ext}`
  const { error } = await supabase.storage.from(LOGO_BUCKET).upload(path, blob, { contentType: blob.type, upsert: false, cacheControl: '31536000' })
  if (error) throw error
  return path
}

/** 카카오맵 검색 링크 (주소가 없으면 장소 이름으로) */
export function mapLink(p: { name: string; address: string }) {
  return `https://map.kakao.com/link/search/${encodeURIComponent(p.address || p.name)}`
}

/** 링크 버튼 문구: 자주 쓰는 곳은 이름으로 */
export function linkLabel(url: string) {
  if (url.includes('open.kakao.com')) return '카카오톡 오픈채팅'
  if (url.includes('instagram.com')) return '인스타그램'
  if (url.includes('band.us')) return '밴드'
  return '동아리 링크'
}
