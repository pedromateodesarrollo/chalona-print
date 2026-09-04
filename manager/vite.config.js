import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// El sitio lo sirve el propio hub desde la carpeta que apunte PRINT_MANAGER.
// Por eso `base` es relativa: funciona igual en la raíz de un dominio que
// colgando de un prefijo.
export default defineConfig({
  plugins: [vue()],
  base: './',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    // En desarrollo el API está en el hub local.
    proxy: { '/v1': 'http://localhost:3071', '/salud': 'http://localhost:3071' },
  },
})
