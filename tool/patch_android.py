"""Passt das von `flutter create` erzeugte Android-Projekt für PingHunt an.

Wird automatisch im GitHub-Bauprozess ausgeführt.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
android = root / "android"

PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.ACCESS_BACKGROUND_LOCATION",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_LOCATION",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
    "android.permission.VIBRATE",
    "android.permission.CAMERA",
]


def patch_manifest():
    path = android / "app" / "src" / "main" / "AndroidManifest.xml"
    text = path.read_text(encoding="utf-8")
    lines = "".join(
        f'    <uses-permission android:name="{p}"/>\n'
        for p in PERMISSIONS
        if p not in text
    )
    text = re.sub(r"(<manifest[^>]*>\n?)", lambda m: m.group(1) + lines, text, count=1)
    text = re.sub(r'android:label="[^"]*"', 'android:label="PingHunt"', text, count=1)
    path.write_text(text, encoding="utf-8")
    print("Manifest angepasst")


def patch_app_gradle():
    for name in ("build.gradle", "build.gradle.kts"):
        path = android / "app" / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 23", text)
        text = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 23", text)
        text = re.sub(r"compileSdk\s*=\s*flutter\.compileSdkVersion", "compileSdk = 35", text)
        text = re.sub(r"targetSdk\s*=\s*flutter\.targetSdkVersion", "targetSdk = 34", text)
        # Desugaring für flutter_local_notifications
        if "coreLibraryDesugaring" not in text:
            if name.endswith(".kts"):
                text = text.replace("compileOptions {", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
                text += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")\n}\n'
            else:
                text = text.replace("compileOptions {", "compileOptions {\n        coreLibraryDesugaringEnabled true", 1)
                text += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'\n}\n"
        path.write_text(text, encoding="utf-8")
        print(f"{name} angepasst")


def patch_settings_gradle():
    for name in ("settings.gradle", "settings.gradle.kts"):
        path = android / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        text = re.sub(
            r'(id\s*\(?\s*"com\.android\.application"\s*\)?\s*version\s*)"[^"]+"',
            r'\g<1>"8.1.0"',
            text,
        )
        text = re.sub(
            r'(id\s*\(?\s*"org\.jetbrains\.kotlin\.android"\s*\)?\s*version\s*)"[^"]+"',
            r'\g<1>"1.9.24"',
            text,
        )
        path.write_text(text, encoding="utf-8")
        print(f"{name} angepasst")


def patch_gradle_properties():
    path = android / "gradle.properties"
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if "suppressUnsupportedCompileSdk" not in text:
        text += "\nandroid.suppressUnsupportedCompileSdk=35\n"
    path.write_text(text, encoding="utf-8")
    print("gradle.properties angepasst")


def patch_wrapper():
    path = android / "gradle" / "wrapper" / "gradle-wrapper.properties"
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"distributionUrl=.*", r"distributionUrl=https\\://services.gradle.org/distributions/gradle-8.3-all.zip", text)
    path.write_text(text, encoding="utf-8")
    print("Gradle-Wrapper angepasst")


if __name__ == "__main__":
    if not android.exists():
        sys.exit("android/ fehlt – zuerst flutter create ausführen")
    patch_manifest()
    patch_app_gradle()
    patch_settings_gradle()
    patch_gradle_properties()
    patch_wrapper()
