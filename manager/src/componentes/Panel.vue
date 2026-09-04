<script setup>
import { ref, onMounted } from 'vue'
import { api, sesion } from '../api.js'
import Agentes from './Agentes.vue'
import Impresoras from './Impresoras.vue'
import Trabajos from './Trabajos.vue'
import Llaves from './Llaves.vue'
import Dominios from './Dominios.vue'
import Descargas from './Descargas.vue'
import Usuarios from './Usuarios.vue'

const yo = ref(null)
const cargando = ref(true)
const seccion = ref('impresoras')

const modo = ref('entrar') // entrar | registrar
const correo = ref('')
const clave = ref('')
const organizacion = ref('')
const error = ref('')
const enviando = ref(false)

const secciones = [
  ['impresoras', 'Impresoras', Impresoras],
  ['trabajos', 'Trabajos', Trabajos],
  ['agentes', 'Agentes', Agentes],
  ['instalar', 'Instalar agente', Descargas],
  ['dominios', 'Dominios', Dominios],
  ['llaves', 'Llaves de API', Llaves],
  ['usuarios', 'Usuarios', Usuarios],
]

onMounted(async () => {
  if (sesion.token) {
    try {
      yo.value = await api.get('/v1/yo')
    } catch {
      sesion.token = ''
    }
  }
  cargando.value = false
})

async function entra() {
  error.value = ''
  enviando.value = true
  try {
    const ruta = modo.value === 'entrar' ? '/v1/auth/login' : '/v1/auth/registro'
    const cuerpo =
      modo.value === 'entrar'
        ? { correo: correo.value, clave: clave.value }
        : { correo: correo.value, clave: clave.value, organizacion: organizacion.value }
    const d = await api.post(ruta, cuerpo)
    sesion.token = d.token
    yo.value = await api.get('/v1/yo')
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

function sale() {
  sesion.token = ''
  yo.value = null
}
</script>

<template>
  <div v-if="cargando" class="contenedor" style="padding: 60px 22px">
    <p class="apagado">Cargando…</p>
  </div>

  <!-- Entrar / crear organización -->
  <div v-else-if="!yo" class="contenedor" style="padding: 56px 22px; max-width: 460px">
    <h1 style="font-size: 28px">
      {{ modo === 'entrar' ? 'Entrar' : 'Crear organización' }}
    </h1>
    <p class="apagado">
      {{ modo === 'entrar'
        ? 'Con la cuenta de tu organización.'
        : 'Tu cuenta será la administradora.' }}
    </p>
    <form class="caja" @submit.prevent="entra">
      <template v-if="modo === 'registrar'">
        <label>Organización</label>
        <input v-model="organizacion" placeholder="Mi empresa" required />
      </template>
      <label>Correo</label>
      <input v-model="correo" type="email" required />
      <label>Clave</label>
      <input v-model="clave" type="password" required minlength="8" />
      <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
      <button class="boton" style="margin-top: 18px" :disabled="enviando">
        {{ enviando ? 'Un momento…' : modo === 'entrar' ? 'Entrar' : 'Crear' }}
      </button>
    </form>
    <p class="apagado" style="margin-top: 18px; font-size: 14px">
      <a href="#" @click.prevent="modo = modo === 'entrar' ? 'registrar' : 'entrar'">
        {{ modo === 'entrar' ? 'Crear una organización nueva' : 'Ya tengo cuenta' }}
      </a>
    </p>
  </div>

  <!-- Panel -->
  <div v-else class="app">
    <aside class="lateral">
      <button
        v-for="[id, titulo] in secciones"
        :key="id"
        :class="{ activo: seccion === id }"
        @click="seccion = id"
      >
        {{ titulo }}
      </button>
      <hr style="border: 0; border-top: 1px solid var(--borde); margin: 14px 0" />
      <button @click="sale">Salir</button>
    </aside>

    <main class="contenido">
      <p class="apagado" style="font-size: 14px; margin-bottom: 14px">
        {{ yo.organizacion }} · {{ yo.correo }} ({{ yo.rol }})
      </p>
      <component
        :is="secciones.find((s) => s[0] === seccion)[2]"
        :yo="yo"
      />
    </main>
  </div>
</template>
