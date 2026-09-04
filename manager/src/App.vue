<script setup>
import { ref, computed, onMounted } from 'vue'
import Landing from './componentes/Landing.vue'
import Docs from './componentes/Docs.vue'
import Panel from './componentes/Panel.vue'

// Router de tres líneas por el hash. Con tres pantallas, traer vue-router es
// más código que el que ahorra, y así el sitio se puede servir desde cualquier
// carpeta sin configurar nada en el servidor.
const ruta = ref(location.hash.slice(1) || '/')
onMounted(() => {
  window.addEventListener('hashchange', () => {
    ruta.value = location.hash.slice(1) || '/'
    if (!location.hash.includes('#')) window.scrollTo(0, 0)
  })
})

const vista = computed(() => {
  if (ruta.value.startsWith('/docs')) return Docs
  if (ruta.value.startsWith('/panel')) return Panel
  return Landing
})
const enDocs = computed(() => ruta.value.startsWith('/docs'))
const enPanel = computed(() => ruta.value.startsWith('/panel'))
</script>

<template>
  <header class="barra">
    <div class="contenedor">
      <a href="#/" class="logo">chalona<span>-print</span></a>
      <nav>
        <a href="#/" :class="{ activo: !enDocs && !enPanel }">Inicio</a>
        <a href="#/docs" :class="{ activo: enDocs }">Documentación</a>
        <a href="#/panel" class="boton chico">Entrar</a>
      </nav>
    </div>
  </header>

  <component :is="vista" />

  <footer class="pie" v-if="!enPanel">
    <div class="contenedor">
      <span>chalona-print · software libre bajo Apache-2.0</span>
      <nav>
        <a href="#/docs">Documentación</a>
        <a href="#/panel">Panel</a>
      </nav>
    </div>
  </footer>
</template>
