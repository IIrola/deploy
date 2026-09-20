# deploy

**El único lugar que describe qué está corriendo en producción.**

Los repos de código publican su imagen y no saben nada del despliegue. Este repo tiene la
composición: qué servicios existen, en qué orden arrancan, qué base usa cada uno, qué está expuesto
a internet y qué no.

---

## Por qué existe un repo aparte

En producción esto es **un solo sistema**: cuatro servicios, una base de datos, un proxy, un orden
de arranque. Pero en desarrollo son repos separados, y con razón — cada uno es un bounded context
distinto.

Eso deja una pregunta sin dueño natural: *¿qué está corriendo ahora mismo, y con qué
configuración?* La respuesta no le pertenece a ninguno de los cuatro. Platform no sabe que existe
Turismo. El frontend no sabe que hay un MariaDB.

**La composición es un artefacto más**, con decisiones propias adentro:

- qué servicios son públicos y cuáles no
- en qué orden corren las migraciones y qué pasa si una falla
- qué variables de entorno existen
- qué versión de cada imagen está desplegada

Eso cambia con el tiempo y merece historial, revisión y rollback igual que el código.

**Por qué no adentro de una API**: el repo que lo alojara quedaría "especial" sin razón de dominio,
y editar el `Caddyfile` dispararía un rebuild de esa imagen. **Por qué no sólo en el VPS**: sin
repo no hay historial, no hay revisión, y el workflow de release no tiene qué clonar.

**Por qué no se llama `pima-deploy` ni `bit-deploy`**: PIMA y BIT son contextos, no el sistema.
Un nombre que contenga una vertical empieza a mentir el día que se sume la segunda.

---

## Situación legacy — lo que hace hoy BitCore

`deploy-prod.yml` del legacy: runner self-hosted → `rsync` del **código fuente** al VPS →
`docker compose up -d --build`.

Tres costos, y son exactamente los que esta forma evita:

| Problema | Consecuencia |
|---|---|
| **El VPS compila** | Necesita el SDK instalado, y lo que corre no es exactamente lo que se probó — se reconstruye en cada despliegue |
| **No hay artefacto** | Lo desplegado es un checkout de git. No hay nada a lo que volver si sale mal |
| **Con cuatro repos se multiplica** | Cuatro copias de fuente en el VPS y ningún lugar que diga qué está corriendo |

A eso se suma que los secretos viajaban por GitHub Actions y se escribían al `.env` en el momento
del despliegue: el pipeline tenía las credenciales de producción.

---

## Situación actual

| | Legacy | Ahora |
|---|---|---|
| Qué viaja al VPS | Código fuente | **Nada** — las imágenes salen de GHCR |
| Dónde se compila | En el VPS | En CI, una vez |
| Artefacto | No hay | Imagen etiquetada por SHA del commit |
| Rollback | Revertir y recompilar | Cambiar una etiqueta en el `.env` |
| Esquema de base | `Database.Migrate()` al arrancar | Contenedor de un solo uso que debe terminar bien |
| Secretos en el pipeline | Sí | **Ninguno** |
| Qué está corriendo | Cuatro checkouts | Este repo |

El release hace `pull` y `up -d`. Nada más.

---

## Las bases de datos son tres problemas distintos

Mezclarlos es lo que convierte esto en un pantano de YAML. Separados, cada uno tiene una respuesta
corta:

### 1 · La instancia

Un servicio de MariaDB con volumen nombrado, en [`docker-compose.yml`](docker-compose.yml). Un
bloque.

### 2 · Bases y usuarios

[`db/init/01-databases.sh`](db/init/01-databases.sh), que MariaDB ejecuta **una sola vez**, cuando
el volumen está vacío. **Cero YAML.**

Una base por contexto y un usuario que sólo llega a la suya — comprobado: cada usuario, al pedir
`SHOW DATABASES`, ve exactamente una. Eso no es higiene decorativa: el hallazgo estructural central
del legacy es que tenía un único `BitCoreDbContext` que todo el código consultaba, sin fronteras.
Una base compartida entre contextos reconstruiría eso, y el día que una vertical haga un `JOIN`
contra las tablas de otra la frontera dejó de existir.

Es un `.sh` y no un `.sql` porque el punto de entrada de MariaDB no sustituye variables dentro de un
`.sql`, y las contraseñas tienen que venir del entorno y no del repositorio.

### 3 · El esquema

Un **migrador que viaja dentro de la imagen de cada API** y corre como contenedor de un solo uso.
Esquema y código comparten etiqueta, así que no se pueden desincronizar. Y tiene que terminar bien
para que su API arranque:

```yaml
depends_on:
  platform-migrate: { condition: service_completed_successfully }
```

Esa es la única línea que impide que el código nuevo corra sobre un esquema viejo.

**Ningún servicio migra al arrancar**, y es deliberado: con varias instancias, todas competirían por
cambiar el esquema. Acá el cambio de esquema es un paso explícito, ordenado, y que se puede ver
fallar antes de que arranque nada.

---

## Por qué el migrador es un programa propio y no `dotnet ef migrations bundle`

Queda escrito porque el bundle es lo que recomienda la documentación, y es la clase de cosa que
alguien vuelve a intentar.

**El bundle alcanza el DbContext construyendo el service provider de la aplicación** — o sea
corriendo `Program` entero, en un hilo aparte. En Platform eso dispara el sembrado de autorización,
que consulta la tabla `Permissions` en una base cuyo esquema todavía no existe. La excepción queda
sin manejar, el proceso muere, y **no se aplica una sola migración** — contra la base vacía que es
exactamente el caso de un migrador.

Se probaron las dos salidas documentadas y ninguna alcanza:

| Intento | Resultado |
|---|---|
| `IDesignTimeDbContextFactory` en Infrastructure | `dotnet ef` sí la usa. **El bundle no la consulta** |
| Guardar el arranque con `EF.IsDesignTime` | **Es `false` dentro del bundle** |
| Generar el bundle con Infrastructure de arranque | Anda fuera del contenedor; dentro de la imagen siguió arrancando la API |

Lo reemplaza `<Contexto>.Migrator`: treinta líneas que resuelven la cadena del entorno (o de
`--connection`), esperan a que el servidor responda, aplican lo pendiente y salen con un código que
el compose puede leer. Sin herramienta y sin ambigüedad. De paso la imagen bajó ~45 MB, porque ya no
instala `dotnet-ef` para construirse.

---

## Qué está publicado y qué no

Dos nombres públicos, y es una decisión de seguridad:

| Servicio | Público | Por qué |
|---|---|---|
| Sitio de la plataforma | sí | Qué hace el producto, para quién y cuánto sale. **Anónimo de punta a punta**: no despliega rutas de sesión, así que no hay forma de establecer una — comprobado contra la imagen, `POST /api/auth/login` responde 404 |
| Sitio de la vertical de turismo | sí, en su propio nombre | El directorio público y lo que turismo le dice a un viajero. Anónimo por el mismo motivo y comprobado igual. **Un nombre por vertical**: sumar la segunda es un servicio, un bloque en el Caddyfile y una línea en el `.env` |
| Consola | sí, en su propio nombre | Sólo autenticada. Su hostname aparte es lo que permite restringirla sin tocar lo que debe ser público. Su proxy de Nitro alcanza las APIs por la red interna |
| Platform | sí | La notificación de pago es anónima y la manda el gateway desde afuera |
| **PIMA** | **no** | Sólo la llaman servicios |
| **Turismo** | **no** | Lo público suyo lo sirve su propio sitio, `tourism-web`, por la red interna |

Y las redes lo **hacen cumplir** en vez de recordarlo — comprobado que el proxy no resuelve los
nombres de PIMA ni de Turismo:

| Red | Quién | Qué |
|---|---|---|
| `data` | base + migradores + APIs | `internal: true` — **la base no tiene ruta a internet** |
| `services` | APIs + frontend | Servicio con servicio, más la salida que PIMA y Platform necesitan para sus proveedores |
| `edge` | proxy + los dos públicos | Lo único que el proxy alcanza |

PIMA y Turismo no están en `edge`, así que publicarlos por accidente pide dos cambios y no uno.

---

## Poner esto en pie

En el VPS, una vez:

```bash
git clone https://github.com/IIrola/deploy.git /opt/bit
cd /opt/bit
cp .env.example .env && chmod 600 .env
$EDITOR .env          # dominios, contraseñas, secretos
docker compose up -d
```

De ahí en más, desplegar es correr el workflow **release** desde GitHub. Trae las imágenes y
levanta; no compila y no lleva secretos.

## Volver atrás

Cada imagen se publica con dos etiquetas: `latest` y el SHA del commit. Para volver a una versión
anterior, en el `.env`:

```
PLATFORM_TAG=<sha del commit que sí andaba>
```

y `docker compose up -d`. No hace falta pipeline ni rebuild.

---

## Sumar una vertical

La topología ya lo contempla. Lo que cambia:

| Pieza | Cuánto |
|---|---|
| Repo nuevo + su `Dockerfile` | Copia del de Turismo |
| Su `publish.yml` | ~10 líneas invocando el workflow reutilizable de este repo |
| Bloque en `db/init/01-databases.sh` | 4 líneas: `CREATE DATABASE` / `CREATE USER` / `GRANT` |
| Bloque en `docker-compose.yml` | Migrador + servicio, copiados de los de Turismo |
| `.env` | Sus tres variables, siguiendo el patrón |
| **Caddy** | **Nada** — las verticales no son públicas |

Una **instancia dentro de** una vertical existente (otro operador, otra empresa) **no toca nada de
esto**: es un Tenant, una Organization y una participación. Ver `RUNBOOK_ALTA_VERTICAL.md` en el
repo legacy.

---

## Cuánto YAML es, en total

La pregunta que originó esta forma:

| Archivo | Cuántos |
|---|---|
| `Dockerfile` (no es YAML) | 6 — tres APIs y las tres aplicaciones del frontend |
| Workflow reutilizable de build | **1**, acá |
| Workflow por repo | 3 × ~10 líneas invocando el reutilizable, más el del frontend |
| `docker-compose.yml` | **1** |
| Workflow de release | **1** |

Tres archivos con contenido real. El resto son llamadas.

---

## Lo que todavía no está resuelto

- **El aprovisionamiento de los clientes de servicio es manual.** Platform tiene que tener las filas
  de `pima-core` y `tourism-core` con sus audiencias y alcances; el `.env` sólo alimenta la punta de
  los consumidores. Sin eso, la vertical responde 503 y el motivo queda sólo en un log. La salida es
  un sembrado idempotente al arrancar, como el del primer administrador — es un cambio de código en
  Platform.
- **La clave de firma de JWT es simétrica y la comparten los tres servicios.** Con HMAC, quien puede
  validar también puede firmar: una vertical comprometida emite tokens de administrador de
  plataforma. Tolerable hoy (tres servicios nuestros, un VPS); deja de serlo al sumar verticales o
  al operar una desde afuera. La corrección es firma asimétrica — Platform guarda la privada, las
  verticales reciben sólo la pública.
- **Sin límites de recursos ni política de backup.** Las dos dependen del VPS real y no se pueden
  elegir bien desde acá.
- **Nada verifica el aprovisionamiento al arrancar** — ni el código de la línea de negocio, ni los
  alcances del cliente de servicio, ni el plan del contrato. Las tres fallan tarde y con mensajes
  que no señalan su causa.
