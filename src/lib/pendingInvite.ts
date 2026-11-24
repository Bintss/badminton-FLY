// 로그인 전에 링크(초대 링크·공유받은 운동 등)로 들어온 경우:
// 로그인(카카오 이동)을 다녀와도 그 화면으로 돌아오게 기억해 둔다
const KEY = 'badminton:returnTo'

export function rememberReturn(path: string) {
  if (!path.startsWith('/') || path === '/' || path.startsWith('/login')) return
  try {
    localStorage.setItem(KEY, path)
  } catch {
    /* 저장 못 하면 링크를 다시 누르면 된다 */
  }
}

export function peekReturn(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    return null
  }
}

export function clearReturn() {
  try {
    localStorage.removeItem(KEY)
  } catch {
    /* 무시 */
  }
}
