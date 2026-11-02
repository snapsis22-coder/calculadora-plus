#!/bin/bash
# Genera Calculadora+-X.Y.Z.dmg con fondo personalizado, layout de iconos y enlace a /Applications.
# Uso: ./build_dmg.sh
set -e

APP="/Applications/Calculadora+.app"
VOL="Calculadora+"
BG="$(dirname "$0")/dmg_assets/background.png"
# Versión leída del Info.plist de la app → nombres de archivo versionados
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
OUT="${1:-$HOME/Desktop/Calculadora+-$VERSION.dmg}"
TMP_DMG="/tmp/Calculadora-rw.dmg"
MNT="/Volumes/$VOL"
echo "==> Versión: $VERSION"

echo "==> Limpieza previa"
hdiutil detach "$MNT" >/dev/null 2>&1 || true
rm -f "$TMP_DMG" "$OUT"

echo "==> Creando DMG temporal de lectura/escritura"
hdiutil create -volname "$VOL" -srcfolder "$APP" -fs HFS+ -format UDRW -size 20m "$TMP_DMG"

echo "==> Montando"
hdiutil attach "$TMP_DMG" -mountpoint "$MNT"

echo "==> Enlace a /Applications, fondo y LÉEME"
ln -s /Applications "$MNT/Applications"
mkdir -p "$MNT/.background"
cp "$BG" "$MNT/.background/background.png"
cat > "$MNT/LÉEME.txt" <<'TXT'
Calculadora+ — Made by snapsis

Arrastra la app sobre "Applications".

Primera vez que la abras (macOS lo pide una sola vez para apps de fuera del App Store):
  1. Ábrela con doble clic: macOS dirá que no puede verificarla. Dale "Listo".
  2. Ve a Ajustes del Sistema -> Privacidad y seguridad.
  3. Abajo, junto a "Calculadora+", pulsa "Abrir de todos modos" y confirma.

Si dice que está "dañada", abre la Terminal y pega:
  xattr -dr com.apple.quarantine "/Applications/Calculadora+.app"

Requisitos: Apple Silicon (M1/M2/M3/M4) + macOS 14+.
TXT

echo "==> Configurando vista del Finder (valores del diseño original)"
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        delay 1
        -- 1) Cromo y tipo de vista PRIMERO (cambian la altura útil de la ventana)
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 2) Opciones de icono + fondo
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 108
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"
        -- 3) Posiciones de los iconos
        set position of item "Calculadora+.app" of container window to {165, 245}
        set position of item "Applications" of container window to {495, 245}
        set position of item "LÉEME.txt" of container window to {330, 400}
        -- 4) Bounds AL FINAL, ya con el cromo definitivo (fijar dos veces ayuda a que persista)
        set the bounds of container window to {200, 100, 860, 663}
        update without registering applications
        delay 1
        set the bounds of container window to {200, 100, 860, 663}
        update without registering applications
        delay 2
        close
        -- 5) Ciclo abrir/cerrar extra para forzar que .DS_Store guarde los bounds
        open
        delay 2
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

echo "==> Desmontando"
sync
sleep 2
hdiutil detach "$MNT"

echo "==> Comprimiendo a UDZO"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -f "$TMP_DMG"

echo "==> Listo:"
ls -lh "$OUT"
