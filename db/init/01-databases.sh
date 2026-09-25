#!/bin/sh
# Bases y usuarios: una base por contexto, y un usuario que solo llega a la suya.
#
# MariaDB corre esto UNA sola vez, cuando el volumen esta vacio. No es "el paso de migracion" —
# el esquema lo aplica el migrador de cada servicio, que viaja dentro de su propia imagen. Aca
# solo existe lo que una API no puede crearse a si misma: su base y su credencial.
#
# Es un .sh y no un .sql porque el punto de entrada de MariaDB no sustituye variables dentro de un
# .sql, y las contrasenas tienen que venir del entorno y no del repositorio.
#
# Idempotente a proposito (IF NOT EXISTS): agregar un contexto nuevo es agregar un bloque y
# correrlo a mano contra un volumen que ya existe.
set -eu

echo "init: creando bases y usuarios por contexto"

mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${PLATFORM_DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PLATFORM_DB_USER}'@'%' IDENTIFIED BY '${PLATFORM_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${PLATFORM_DB_NAME}\`.* TO '${PLATFORM_DB_USER}'@'%';

CREATE DATABASE IF NOT EXISTS \`${PIMA_DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PIMA_DB_USER}'@'%' IDENTIFIED BY '${PIMA_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${PIMA_DB_NAME}\`.* TO '${PIMA_DB_USER}'@'%';

CREATE DATABASE IF NOT EXISTS \`${TOURISM_DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${TOURISM_DB_USER}'@'%' IDENTIFIED BY '${TOURISM_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${TOURISM_DB_NAME}\`.* TO '${TOURISM_DB_USER}'@'%';

CREATE DATABASE IF NOT EXISTS \`${BIDA_DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${BIDA_DB_USER}'@'%' IDENTIFIED BY '${BIDA_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${BIDA_DB_NAME}\`.* TO '${BIDA_DB_USER}'@'%';

FLUSH PRIVILEGES;
SQL

echo "init: listo — 4 bases, 4 usuarios, ninguno con acceso a la base de otro"
