# bit-deploy

El unico lugar que describe que esta corriendo en produccion.

Los cuatro repos de codigo — [PIMAPlatform](https://github.com/IIrola/PIMAPlatform),
[PIMACore](https://github.com/IIrola/PIMACore), [TourismCore](https://github.com/IIrola/TourismCore)
y [BitFront](https://github.com/IIrola/BitFront) — publican su imagen a GHCR y no saben nada del
despliegue. Este repo tiene el compose, el proxy, el SQL de inicializacion y el workflow de
release.

## Cuanto YAML es, en total

La pregunta que origino esta forma. La respuesta:

| Archivo | Cuantos |
|---|---|
| `Dockerfile` (no es YAML) | 4, uno por repo de codigo |
| Workflow reutilizable de build | **1**, aca |
| Workflow por repo que lo invoca | 4 × ~10 lineas |
| `docker-compose.yml` | **1** |
| Workflow de release | **1** |

Tres archivos con contenido real. El resto son llamadas.

## Las bases de datos son tres problemas distintos

Mezclarlos es lo que convierte esto en un pantano. Separados, cada uno tiene una respuesta corta:

1. **La instancia** — un servicio de MariaDB con volumen nombrado. Un bloque del compose.
2. **Bases y usuarios** — [`db/init/01-databases.sh`](db/init/01-databases.sh), que MariaDB corre
   **una sola vez**, cuando el volumen esta vacio. Tres bases, tres usuarios, cada uno sin acceso
   a la base de los otros. Cero YAML.
3. **El esquema** — el migrador que viaja **dentro de la imagen de cada API**. Corre como
   contenedor de un solo uso y tiene que terminar bien para que su API arranque
   (`condition: service_completed_successfully`). Esquema y codigo comparten etiqueta, asi que no
   se pueden desincronizar.

El punto 3 es el que mas cambia las cosas. Ningun servicio migra al arrancar — con varias
instancias, todas competirian por cambiar el esquema. Aca el cambio de esquema es un paso
explicito, ordenado, y que se puede ver fallar antes de que corra el codigo nuevo.

## Poner esto en pie

En el VPS, una vez:

```bash
git clone https://github.com/IIrola/bit-deploy.git /opt/bit
cd /opt/bit
cp .env.example .env && chmod 600 .env
$EDITOR .env          # completar dominios, contrasenas, secretos
docker compose up -d
```

De ahi en mas, desplegar es correr el workflow **release** desde GitHub. Trae las imagenes y
levanta; no compila y no lleva secretos.

## Volver atras

Cada imagen se publica con dos etiquetas: `latest` y el SHA del commit. Para volver a una version
anterior, en el `.env`:

```
PLATFORM_TAG=<sha del commit que si andaba>
```

y `docker compose up -d`. No hace falta pipeline ni rebuild.

## Que esta publicado y que no

Solo **dos** nombres publicos, y es una decision:

| Servicio | Publico | Por que |
|---|---|---|
| BitFront | si | Es lo que usa una persona |
| Platform | si | La notificacion de pago es anonima y la manda el gateway desde afuera |
| PIMA | **no** | Solo la llaman servicios |
| BIT | **no** | Lo publico suyo lo sirve BitFront |

PIMA y BIT ademas no estan en la red `edge` del compose, asi que publicarlos por accidente
requiere dos cambios y no uno.

## Lo que el pipeline todavia no resuelve

**El aprovisionamiento de los clientes de servicio.** Platform tiene que tener las filas de
`pima-core` y `tourism-core` con sus audiencias y alcances, y PIMA y BIT tienen que llevar el
secreto que coincide. Hoy el `.env` alimenta una sola punta: la de los consumidores. La otra es un
paso manual del runbook, y sin el, la vertical responde 503 con el motivo solo en un log.

La salida natural es la que Platform ya usa para el primer administrador: un sembrado idempotente
al arrancar, que asegure el cliente a partir de configuracion. Es un cambio de codigo en Platform
y por eso no esta aca.
