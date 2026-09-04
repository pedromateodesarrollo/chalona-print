<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from '../api.js'

const agentes = ref([])
const error = ref('')
let temporizador

async function carga() {
  try {
    agentes.value = (await api.get('/v1/agentes')).agentes
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

// Dos clics para lo que no tiene vuelta atrás, en vez de un `confirm()` del
// navegador que nadie lee.
const confirmando = ref(null)
async function borra(a) {
  if (confirmando.value !== a.id) {
    confirmando.value = a.id
    setTimeout(() => (confirmando.value === a.id ? (confirmando.value = null) : null), 4000)
    return
  }
  await api.del(`/v1/agentes/${a.id}`)
  confirmando.value = null
  await carga()
}

const hora = (s) => (s ? new Date(s).toLocaleString() : '—')


onMounted(() => {
  carga()
  temporizador = setInterval(carga, 5000)
})
onUnmounted(() => clearInterval(temporizador))
</script>

<template>
  <div class="cabecera-seccion"><h2>Agentes</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div class="tarjeta" style="margin-bottom: 18px">
    <h3>Conectar una computadora</h3>
    <p class="apagado">
      El agente se instala en la máquina que tiene las impresoras y aparece sola
      en esta lista. En <strong>Instalar agente</strong> están el programa y el
      comando ya preparado con la dirección de este hub.
    </p>
  </div>

  <table v-if="agentes.length">
    <thead>
      <tr><th>Computadora</th><th>Dominio</th><th>Estado</th><th>Impresoras</th><th>Versión</th><th>Última conexión</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="a in agentes" :key="a.id">
        <td>
          <strong>{{ a.nombre }}</strong>
          <div class="apagado" style="font-size: 13px">{{ a.plataforma }}</div>
        </td>
        <td class="apagado">{{ a.dominio_nombre || '—' }}</td>
        <td>
          <span class="estado">
            <span class="punto" :class="a.conectado ? 'ok' : 'mal'"></span>
            {{ a.conectado ? 'Conectado' : 'Sin conexión' }}
          </span>
        </td>
        <td>{{ a.impresoras }}</td>
        <td class="apagado">{{ a.version || '—' }}</td>
        <td class="apagado" style="font-size: 13px">{{ hora(a.ultima_conexion) }}</td>
        <td>
          <button class="boton chico" :class="confirmando === a.id ? 'peligro' : 'suave'" @click="borra(a)">
            {{ confirmando === a.id ? '¿Seguro?' : 'Quitar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
  <p v-else class="apagado">Ninguna computadora conectada todavía.</p>
</template>
