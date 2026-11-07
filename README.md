# Sistema Valle API

Este directorio es el paquete Dart de la API. La aplicación Flutter está en
`C:\sistemavalle`; son proyectos separados y se comunican por HTTP.

## Estructura

```text
apisistemavalle/
  bin/
    migrate.dart
    seed.dart
    server.dart
  lib/
    database/
      database.dart
      migration_runner.dart
      migrations/
        2026_06_19_231457_create_clientes_table.sql
        ...
        check_schema.sql
        ...
    models/
    routes/
    services/
    seeders/
    utils/
    server.dart
  public/
    docs.html
    openapi.yaml
  test/
  .env.example
  pubspec.yaml
sistemavalle/
  lib/
  android/
  assets/
  test/
  web/
  pubspec.yaml
```

Los modelos, factories, providers, pantallas y servicios de interfaz pertenecen
a Flutter (`C:\sistemavalle\lib`). La API contiene su servidor y sus seeders
(`C:\apisistemavalle\lib`); no duplica los componentes de la app.

## Base de datos compartida

Laravel (web y API web) y Dart (API móvil) son procesos independientes que se
conectan a la misma base MySQL configurada en Laravel. Dart usa esa base para
consultar y guardar los datos de la API móvil; las rutas web se reenvían a
Laravel por HTTP. Dart no necesita una base exclusiva ni otro servidor MySQL.

La base ya configurada en el `.env` de Laravel se administra desde Laravel.
Ejecuta sus migraciones únicamente allí:

```powershell
cd C:\laragon\www\pvalle
php artisan migrate
```

En `C:\apisistemavalle`, crea `.env` desde `.env.example` y copia los valores
`DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME` y `DB_PASSWORD` del `.env` de
Laravel. Para Dart, `DB_USER` puede tener el mismo valor que `DB_USERNAME` y
`DB_NAME` el mismo que `DB_DATABASE`. Configura también `LARAVEL_API_URL` con la
URL de Laravel. No copies credenciales a chats ni subas el archivo `.env`.

**No ejecutes `dart run bin/migrate.dart` con la base compartida.** Los archivos
SQL de `lib/database/migrations/` son copias para una base Dart independiente
que no tienes configurada ahora; no se aplican a la base Laravel. Mantén
`MIGRATIONS_ENABLED=false`. Si Dart necesita un cambio de esquema, hazlo con
una migración de Laravel para que ambas APIs sigan usando el mismo esquema.

El servidor no ejecuta migraciones al arrancar. La documentación de la API
está en `public/docs.html` y `public/openapi.yaml`. Los seeders de Dart usan
`DB_NAME`/`DB_DATABASE` y solo deben ejecutarse en desarrollo, con cuidado de
que insertan datos en la base configurada.

La app Flutter no se conecta a MySQL: se comunica por HTTP con la API Dart.
El registro móvil crea únicamente clientes en la tabla compartida `clientes`.
Las cuentas de personal y sus roles continúan administrándose desde el sistema
existente; no se crean empleados desde el registro móvil.

## Configuración e inicio

1. Inicia MySQL y Laravel, por ejemplo:

   ```powershell
   cd C:\laragon\www\pvalle
   php artisan serve
   ```

2. En `C:\apisistemavalle`, copia `.env.example` a `.env`, configura
   `LARAVEL_API_URL` y copia las credenciales de base MySQL desde Laravel. No
   compartas ni subas `.env`.

3. Desde la raíz de este proyecto, instala dependencias e inicia la API:

   ```powershell
   cd C:\apisistemavalle
   dart pub get
   dart run bin/server.dart
   ```

   La API escucha por defecto en el puerto `8080`. `HOST=0.0.0.0` permite que
   otros dispositivos de la red local puedan conectarse. El endpoint de salud
   está en `http://127.0.0.1:8080/api/health`.
   Abre `http://127.0.0.1:8080/` o `http://127.0.0.1:8080/docs` para consultar
   la referencia interactiva ReDoc, o `http://127.0.0.1:8080/openapi.yaml` para
   descargar su especificación. ReDoc documenta los perfiles Administrador,
   Recepcionista y Cliente, sus permisos y las rutas móviles y Laravel.
   ReDoc carga su visor desde un CDN y requiere acceso a internet en el navegador.

## Seeders de desarrollo

Los seeders requieren `APP_ENV=local` o `APP_ENV=testing`,
`SEED_DEVELOPMENT_DATA=true`, la opción `--confirm-development` y una
`DEMO_SEED_PASSWORD` de al menos 12 caracteres. Configura esos valores en el
`.env` local y ejecuta:

```powershell
cd C:\apisistemavalle
dart run bin/seed.dart --confirm-development
```

La contraseña demo no se guarda en el código ni se imprime. No habilites la
siembra contra producción.

## Desplegar la API Dart en Render

En Render crea un **Web Service** conectado al repositorio de esta API y
selecciona **Docker** como entorno. Usa `Dockerfile` en la raíz del proyecto.
No hace falta configurar un comando de build o start personalizado: Docker
instala las dependencias y ejecuta `dart run bin/server.dart`. El servidor
escucha en `0.0.0.0` y toma el puerto de `PORT`, que Render proporciona.

Configura estas variables en **Environment** del servicio, copiando los datos
de conexión de forma segura desde el proveedor de base de datos. No uses
`127.0.0.1`, `localhost` ni credenciales de la computadora local en Render:

| Variable | Valor |
| --- | --- |
| `DB_HOST` | Host público o privado accesible desde Render para MySQL |
| `DB_PORT` | Puerto MySQL, normalmente `3306` |
| `DB_DATABASE` | Nombre de la misma base MySQL que usa Laravel |
| `DB_USERNAME` | Usuario MySQL de la aplicación |
| `DB_PASSWORD` | Contraseña MySQL, guardada como variable secreta |
| `LARAVEL_API_URL` | URL alcanzable de Laravel terminada en `/api` |
| `HOST` | `0.0.0.0` |
| `CORS_ALLOWED_ORIGINS` | Origen HTTPS exacto de Flutter Web, si se usa |

Render debe poder alcanzar MySQL desde la red. Si MySQL está solo dentro de
Laragon en tu PC, no será accesible desde Render; usa un servidor MySQL
desplegado con acceso de red y TLS compatible. El login de personal y las
rutas que se reenvían requieren que `LARAVEL_API_URL` también sea alcanzable
desde Render. Ninguna de estas variables se coloca en el Dockerfile ni en el
repositorio.

Configura el **Health Check Path** de Render como `/api/health`. Para conservar
los comprobantes subidos a la API, agrega un Persistent Disk al servicio con
punto de montaje `/var/data`; el contenedor guarda esos archivos en
`/var/data/mobile-comprobantes`. Sin ese disco, los archivos del contenedor
pueden perderse al redeplegar o reiniciar el servicio. Las variables del
Dashboard de Render se mantienen fuera del repositorio.

No ejecutes `dart run bin/migrate.dart` ni los seeders al desplegar contra la
base compartida. Laravel sigue siendo responsable de las migraciones.

## App Flutter y teléfono

Inicia la app desde su propio proyecto:

```powershell
cd C:\sistemavalle
flutter pub get
flutter run
```

En un emulador Android, la app usa `10.0.2.2` para llegar al servidor de la PC.
En un teléfono físico conectado a la misma red Wi-Fi, averigua la IP local de
la PC y arranca Flutter con esa dirección:

```powershell
cd C:\sistemavalle
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080/api
```

Reemplaza `192.168.1.10` por la IP real de la PC. Mantén la API ejecutándose y
permite el puerto `8080` en el firewall de Windows si el teléfono no logra
conectarse. No uses `localhost` como URL de API desde el teléfono: apuntaría al
propio teléfono.

## Verificación

Para la API, desde `C:\apisistemavalle`:

```powershell
dart analyze
dart test
```

Para Flutter, desde `C:\sistemavalle`:

```powershell
flutter analyze lib test
flutter test
```
