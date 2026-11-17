#!/bin/bash
set -euo pipefail

MALI_PACKAGE=libmali-bifrost-g52-g13p0-x11-wayland-gbm

require_vendor_mali()
{
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$MALI_PACKAGE" 2>/dev/null)" != installed ]; then
        echo "ERROR: Qt runtime requires the installed vendor Mali package: $MALI_PACKAGE" >&2
        exit 1
    fi
}

install_qt_runtime()
{
    require_vendor_mali
    if [ "$(dpkg-query -W -f='${db:Status-Status}' anima-qt5-eglfs-runtime 2>/dev/null)" = installed ]; then
        echo "ERROR: anima-qt5-eglfs-runtime conflicts with Ubuntu Qt; use a clean base." >&2
        exit 1
    fi
    local packages=(
        libdrm2 libdrm-common
        libqt5gui5t64 libqt5quick5 python3-pyqt5 python3-pyqt5.qtquick
        qml-module-qtquick2 qml-module-qtquick-window2
        qml-module-qtquick-layouts qml-module-qtquick-controls2
        qml-module-qtquick-templates2 qml-module-qtgraphicaleffects
        python3-qrcode libgudev-1.0-0
    )
    apt-mark unhold libdrm2 libdrm-common
    if ! apt-get --simulate --no-remove --no-install-recommends --no-install-suggests \
        install "${packages[@]}"; then
        echo "ERROR: Qt runtime dependency preflight failed." >&2
        exit 1
    fi
    if ! apt-get -y --no-remove --no-install-recommends --no-install-suggests \
        install "${packages[@]}"; then
        echo "ERROR: Qt runtime installation failed." >&2
        exit 1
    fi
    require_vendor_mali
    if ! dpkg --purge mesa-vulkan-drivers; then
        echo "ERROR: Cannot remove mesa-vulkan-drivers without breaking dependencies." >&2
        exit 1
    fi
}

verify_qt_runtime()
{
    local audit_output mali_changes
    require_vendor_mali
    apt-get check
    audit_output=$(dpkg --audit)
    mali_changes=$(dpkg -V "$MALI_PACKAGE")
    if [ -n "$audit_output$mali_changes" ]; then
        printf 'ERROR: Qt runtime package verification failed:\n%s\n%s\n' \
            "$audit_output" "$mali_changes" >&2
        exit 1
    fi
    PYTHONDONTWRITEBYTECODE=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali:/usr/lib/aarch64-linux-gnu \
        python3 - <<'PY'
import ctypes
from pathlib import Path
from PyQt5 import QtCore, QtGui, QtQml, QtQuick, QtWidgets
import qrcode

plugins = Path('/usr/lib/aarch64-linux-gnu/qt5/plugins')
for plugin in ('platforms/libqeglfs.so',
               'egldeviceintegrations/libqeglfs-kms-integration.so'):
    path = plugins / plugin
    if not path.is_file():
        raise SystemExit(f'Missing Qt plugin: {path}')
    ctypes.CDLL(str(path))
for library in ('libEGL.so.1', 'libGLESv2.so.2', 'libgbm.so.1', 'libdrm.so.2',
                'libgudev-1.0.so.0'):
    ctypes.CDLL(library)
app = QtGui.QGuiApplication([])
engine = QtQml.QQmlEngine()
component = QtQml.QQmlComponent(engine)
component.setData(b'''import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15
import QtQuick.Templates 2.15 as T
import QtQuick.Layouts 1.15
import QtGraphicalEffects 1.15
Item {}''', QtCore.QUrl())
item = component.create()
if item is None:
    raise SystemExit('\n'.join(error.toString() for error in component.errors()))
print(f'Qt {QtCore.QT_VERSION_STR}; PyQt {QtCore.PYQT_VERSION_STR}; QML/EGLFS dependencies OK')
PY
    mkdir -p /usr/share/armsom
    dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n' \
        > /usr/share/armsom/ubuntu-qt5-package-manifest.tsv
}

cleanup_vendor_graphics()
(
    # Preserve the legacy best-effort cleanup, including missing optional X files.
    set +e
    if [ -e "/usr/lib/arm-linux-gnueabihf/dri" ] ;
    then
        # Only preload libdrm-cursor for X
        sed -i "1aexport LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libdrm-cursor.so.1" /usr/bin/X
        cd /usr/lib/arm-linux-gnueabihf/dri/
        cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
        rm /usr/lib/arm-linux-gnueabihf/dri/*.so
        mv /*.so /usr/lib/arm-linux-gnueabihf/dri/
    elif [ -e "/usr/lib/aarch64-linux-gnu/dri" ];
    then
        # Only preload libdrm-cursor for X
        sed -i "1aexport LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libdrm-cursor.so.1" /usr/bin/X
        cd /usr/lib/aarch64-linux-gnu/dri/
        cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
        rm /usr/lib/aarch64-linux-gnu/dri/*.so
        mv /*.so /usr/lib/aarch64-linux-gnu/dri/
        rm /etc/profile.d/qt.sh
    fi
    return 0
)

case "${1:-}" in
    install) ;;
    *) echo "Usage: $0 install" >&2; exit 2 ;;
esac

if [ -r /etc/hostname ] && [ "$(cat /etc/hostname)" = anima ]; then
    install_qt_runtime
    verify_qt_runtime
else
    apt-get install -fy --allow-downgrades /packages/libdrm/*.deb || true
    cleanup_vendor_graphics
fi
