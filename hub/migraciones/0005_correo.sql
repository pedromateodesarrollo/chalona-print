-- El correo de salida de cada organización: por él salen los enlaces para
-- poner clave (el de «¿Olvidaste tu clave?» y el que genera un admin para una
-- persona). print-server es independiente: no usa el correo de ningún otro
-- sistema, cada organización pone el suyo desde el panel (Organización →
-- Correo de salida). Sin él, la entrada no ofrece recuperar la clave y el
-- enlace de un admin se comparte a mano.
--
-- {host, puerto, seguridad: tls|starttls|ninguna, remitente, usuario, clave,
--  nombre}. La clave va en claro porque hace falta para autenticar ante el
-- servidor de correo; la API nunca la devuelve (solo `clave_puesta`). Ver
-- SECURITY.md.

alter table print.org add column if not exists correo jsonb not null default '{}'::jsonb;
