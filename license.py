"""Hardware-Lizenz: bindet die Installation an die Pi-Seriennummer.

`install.sh` erzeugt beim Setup:
  - `/opt/safety-cross/.secret`     (zufälliges Secret, NICHT in Git)
  - `/opt/safety-cross/license.key` (= HMAC-SHA256(seriennummer, secret))

Beim Start prüft die App: stimmt der hinterlegte Key zur Seriennummer dieses Pi?
  - Gleicher Pi (Klon/Backup)   -> läuft
  - Anderer Pi (Kopie)          -> gesperrt
  - Kein Pi (Dev/VM, kein /proc/cpuinfo) -> erlaubt
"""
import hashlib
import hmac
import os


def _license_path():
    return os.environ.get("SAFETY_LICENSE", "/opt/safety-cross/license.key")


def _secret_path():
    return os.environ.get("SAFETY_SECRET", "/opt/safety-cross/.secret")


def get_serial():
    """Seriennummer des Raspberry Pi (None, wenn kein Pi)."""
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.lower().startswith("serial"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        return None
    return None


def compute_key(serial, secret):
    return hmac.new(secret.encode(), serial.encode(), hashlib.sha256).hexdigest()


def is_valid():
    """True, wenn die Lizenz zur Hardware passt (oder Dev-Modus)."""
    serial = get_serial()
    if not serial:
        # Kein Pi (Entwicklung/VM) -> nicht sperren
        return True
    if not os.path.exists(_license_path()):
        return False
    try:
        with open(_secret_path()) as f:
            secret = f.read().strip()
        with open(_license_path()) as f:
            stored = f.read().strip()
    except OSError:
        return False
    if not secret or not stored:
        return False
    return hmac.compare_digest(stored, compute_key(serial, secret))
