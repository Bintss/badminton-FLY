/** 배포 빌드에서만 서비스워커 등록 (홈 화면 추가 + 오프라인 안내). 하위 경로(/repo/) 대응 */
export function registerServiceWorker() {
  if (!import.meta.env.PROD || !('serviceWorker' in navigator)) return
  const base = import.meta.env.BASE_URL
  window.addEventListener('load', () => {
    navigator.serviceWorker.register(`${base}sw.js`, { scope: base }).catch(() => {
      /* 등록 실패해도 앱 사용에는 지장 없음 */
    })
  })
}
