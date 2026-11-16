import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig, loadEnv } from 'vite'

// GitHub Pages 프로젝트 페이지(username.github.io/<repo>/)면 VITE_BASE_PATH=/<repo>/
// 커스텀 도메인이면 '/' 그대로
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    base: env.VITE_BASE_PATH || '/',
    plugins: [react(), tailwindcss()],
  }
})
