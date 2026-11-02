# Calculadora+

Calculadora nativa de macOS, escrita en Swift y SwiftUI. Hace lo que hace la de Apple, más
las cosas que a mí me faltaban.

## Qué añade sobre la calculadora del sistema

- **La operación completa a la vista.** Mientras escribes ves `200 + 10%`, no solo el último
  número. Al dar `=` el resultado queda arriba y la expresión pasa a la línea gris.
- **Porcentaje que se comporta.** Con una suma o resta pendiente, `%` calcula el porcentaje
  *del primer número* — `200 + 10%` da 220, no 200,1. Y no convierte de inmediato: se ve
  `10%` tal cual hasta que resuelves.
- **Varias ventanas.** `Cmd+N`, o clic derecho en el ícono del Dock.
- **Mantener al frente**, con palomita en el menú Ventana.
- **Menús en español**, no la mezcla a medias del sistema.
- Borrar con retroceso entiende el contexto: sobre `200 +` quita el operador y te devuelve al
  200; sobre `10%` quita solo el `%`.

## Instalar

Descarga el `.dmg` de [Releases](../../releases), ábrelo y arrastra la app a Applications.

La primera vez macOS avisará que viene de un desarrollador no identificado: clic derecho sobre
la app → **Abrir**, o Ajustes del Sistema › Privacidad y Seguridad › *Abrir de todos modos*.
Es porque está firmada con un certificado propio y no con uno de pago de Apple.

Las versiones siguientes se instalan desde la propia app: al abrir (como mucho una vez al día) o desde el menú **Calculadora+ › Buscar actualizaciones…**, avisa si hay una nueva en Releases y la instala solo si pulsas **Actualizar**. Antes comprueba que el DMG coincida con el hash que publica GitHub y que la app esté firmada con el mismo certificado; la versión vieja va a la Papelera. Como la descarga no pasa por el navegador, macOS no vuelve a pedir *Abrir de todos modos*.

## Compilar

Requiere macOS 14 o superior y las Command Line Tools de Xcode.

```
./build_app.sh             compila, firma e instala en /Applications
./build_dmg.sh             arma el DMG
./publicar.sh 1.7.0 "…"    etiqueta y crea la Release con el DMG
```

El historial de cambios está en [CHANGELOG.txt](CHANGELOG.txt).

## Licencia

MIT — ver [LICENSE](LICENSE).
