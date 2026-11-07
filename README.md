# Reembolsos

Aplicación móvil en español para registrar gastos pagados personalmente y controlar reembolsos manuales. Moneda CLP sin decimales; fecha civil de America/Santiago.

**Aplicación:** https://marcelobarcia.github.io/reembolsos/

## Acceso

Ingresar el correo y solicitar un enlace de acceso de Supabase Auth. Abrirlo en el mismo dispositivo. No hay conciliación ni conexión bancaria. Los datos de cada cuenta están aislados por propietario; no se comparten entre correos.

En iPhone: Compartir → Agregar a inicio. En Android: menú del navegador → Instalar aplicación.

## Uso

1. Registrar un gasto: monto, comercio, descripción, fecha y responsable. Granero Fino es la opción inicial. Se puede agregar una persona y reutilizarla; boleta opcional (imagen o PDF, máximo 15 MB).
2. En Pendientes seleccionar gastos de un responsable o su mes completo. El consolidado corresponde al mes del gasto.
3. Recibir la transferencia por fuera de la aplicación y registrar fecha y comprobante opcional. Confirmar solo cuando el dinero ya se recibió.
4. Consultar transferencias y adjuntos en Historial, agrupado por mes de transferencia. Deshacer un registro devuelve sus gastos a pendientes y no revierte movimientos bancarios.

El menú ⋯ permite exportar gastos y reembolsos a CSV UTF-8 con BOM, separador punto y coma y protección contra fórmulas al abrir en Excel. Los archivos adjuntos no se incluyen en el CSV.

## Desarrollo y publicación

Node 24. Dependencias fijadas y lockfile versionado.

```sh
npm ci
npm test
npm run build
python3 -m http.server 4173 --directory dist
```

La aplicación estática se compila con esbuild. El workflow `.github/workflows/pages.yml` prueba, construye y publica cada push a main mediante GitHub Pages. Las rutas de recursos son relativas para funcionar bajo `/reembolsos/`.

Solo la URL de Supabase y su clave **publicable** se incluyen en `src/config.js`. No agregar claves secretas, service_role, contraseñas, boletas o datos financieros al repositorio.

## Base de datos y seguridad

Proyecto `reembolsos` (`bafpawpmdkyhgcqdsuoj`) en la organización confirmada de Granero (`ptbbfezhgctixvuozerd`). No usa MB ni MiniCRM.

- Migración inicial en `supabase/migrations/`; `supabase/schema.sql` es su copia legible para instalación en un proyecto vacío. No ejecutarla nuevamente sobre el proyecto desplegado.
- RLS en `responsibles`, `expenses` y `reimbursements`, lecturas restringidas por `auth.uid() = owner_id`.
- Los clientes solo pueden leer datos financieros y crear responsables propios. Toda mutación financiera pasa por `public.mutate`, una envoltura invoker de una función privilegiada en el esquema no expuesto `private`, con UID explícito, búsqueda vacía y permisos limitados.
- Un bloqueo transaccional por propietario serializa guardado, eliminación, registro y anulación. Reembolso y vinculación de gastos ocurren en una sola transacción, validando propietario, responsable y estado pendiente. El ID de solicitud hace seguros los reintentos. Los clientes no pueden eludirlo actualizando tablas directamente.
- Los reembolsos anulados conservan su registro e IDs para trazabilidad; los gastos vuelven a pendientes. Gastos ya reembolsados no pueden editarse ni eliminarse.
- Bucket `attachments` privado, archivos inmutables bajo `<auth.uid()>/<uuid>.<ext>`. Solo el propietario puede descargar; subidas limitadas por tipo y tamaño. Eliminación permitida solo para archivos sin referencias.
- La aplicación no persiste formularios financieros en almacenamiento local; Auth conserva su sesión. El service worker solo cachea recursos estáticos del mismo sitio, nunca datos, tokens ni adjuntos. Se requiere internet para leer o guardar datos.

Auth tiene Site URL y redirección exacta `https://marcelobarcia.github.io/reembolsos/`. El envío de enlaces usa el proveedor de correo del proyecto Supabase; su servicio predeterminado tiene límites y restricciones de destinatarios. Si se necesita otra casilla o más volumen, configurar SMTP propio (sin contratar servicios automáticamente).

## Verificación

- `npm test`: fechas de Chile, exportación CSV segura, agrupación mensual y selección de responsable único.
- `tests/database.sql`: ejecutar como postgres; crea pruebas dentro de una transacción que termina en ROLLBACK. Verifica RLS con dos propietarios, operación atómica, duplicados, idempotencia, bloqueo de edición/borrado reembolsado, escritura directa y anulación.
- `tests/integration.mjs`: QA contra API real con dos cuentas efímeras autorizadas. Recibe JSON por stdin (`emailA`, `emailB`, `password`, `a`, `b`) sin guardar credenciales. Prueba una carrera concurrente real, reintentos simultáneos, RLS y Storage privado. Usar solo cuentas de prueba y retirarlas después.
- Verificación visual del flujo completo en navegador y de la interfaz móvil. Las cuentas y datos temporales se eliminan al terminar; producción queda sin gastos ficticios.
