<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api.js'

const props = defineProps({ yo: Object })
const usuarios = ref([])
const error = ref('')
const nuevo = ref({ correo: '', clave: '', rol: 'operador', nombre: '' })
const confirmando = ref(null)
const cambiando = ref(null)
const claveNueva = ref('')

async function carga() {
  try {
    usuarios.value = (await api.get('/v1/usuarios')).usuarios
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  try {
    await api.post('/v1/usuarios', nuevo.value)
    nuevo.value = { correo: '', clave: '', rol: 'operador', nombre: '' }
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function cambiaClave(u) {
  try {
    await api.post(`/v1/usuarios/${u.id}/clave`, { clave: claveNueva.value })
    cambiando.value = null
    claveNueva.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function borra(u) {
  if (confirmando.value !== u.id) {
    confirmando.value = u.id
    setTimeout(() => (confirmando.value === u.id ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/usuarios/${u.id}`)
    confirmando.value = null
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

const hora = (s) => (s ? new Date(s).toLocaleString() : 'nunca')
onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Usuarios</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div class="tarjeta" style="margin-bottom: 20px" v-if="props.yo.rol === 'admin'">
    <h3>Dar de alta</h3>
    <div style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end">
      <div style="flex: 2; min-width: 200px">
        <label>Correo</label>
        <input v-model="nuevo.correo" type="email" />
      </div>
      <div style="flex: 1; min-width: 150px">
        <label>Clave</label>
        <input v-model="nuevo.clave" type="password" minlength="8" />
      </div>
      <div style="flex: 1; min-width: 130px">
        <label>Rol</label>
        <select v-model="nuevo.rol">
          <option value="operador">Operador</option>
          <option value="admin">Administrador</option>
        </select>
      </div>
      <button class="boton" @click="crea" :disabled="!nuevo.correo || nuevo.clave.length < 8">
        Crear
      </button>
    </div>
  </div>

  <table>
    <thead>
      <tr><th>Correo</th><th>Rol</th><th>Último acceso</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="u in usuarios" :key="u.id">
        <td>
          {{ u.correo }}
          <span v-if="u.id === props.yo.id" class="apagado">(tú)</span>
        </td>
        <td class="apagado">{{ u.rol }}</td>
        <td class="apagado" style="font-size: 13px">{{ hora(u.ultimo_acceso) }}</td>
        <td style="white-space: nowrap">
          <template v-if="cambiando === u.id">
            <input
              v-model="claveNueva"
              type="password"
              placeholder="Clave nueva"
              style="max-width: 170px; display: inline-block"
              @keyup.enter="cambiaClave(u)"
            />
            <button class="boton chico" style="margin-left: 6px" @click="cambiaClave(u)">Guardar</button>
          </template>
          <template v-else>
            <button class="boton suave chico" @click="cambiando = u.id">Clave</button>
            <button
              v-if="u.id !== props.yo.id && props.yo.rol === 'admin'"
              class="boton chico"
              :class="confirmando === u.id ? 'peligro' : 'suave'"
              style="margin-left: 6px"
              @click="borra(u)"
            >
              {{ confirmando === u.id ? '¿Seguro?' : 'Quitar' }}
            </button>
          </template>
        </td>
      </tr>
    </tbody>
  </table>
</template>
