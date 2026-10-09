-- Enlace de un solo uso para poner clave.
--
-- Lo pide la persona desde la entrada («¿Olvidaste tu clave?», vence en una
-- hora) o lo genera un admin para alguien de su organización (siete días). El
-- token se enseña una vez —en el correo o al admin— y aquí queda solo su
-- sha256, como las llaves de API: quien lea la base no puede usarlo.
--
-- Pedir uno nuevo invalida el anterior (hay uno por persona), y usarlo lo
-- borra. Hasta que se usa, la clave de antes sigue valiendo: pedir el enlace
-- no le cierra la puerta a nadie.

alter table print.usuario
  add column if not exists invitacion_hash  text,
  add column if not exists invitacion_vence timestamptz;

create index if not exists usuario_invitacion_idx
  on print.usuario (invitacion_hash) where invitacion_hash is not null;
