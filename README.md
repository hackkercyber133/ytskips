# ytskips

Auto-skip iklan YouTube. Android only.

## Pasang
1. `flutter create --org com.example --project-name ytskips ytskips`
2. Salin SEMUA isi folder ini ke dalam proyek hasil langkah 1 (timpa file yang sama).
3. `cd ytskips && flutter pub get && flutter run` (HP Android, USB debugging).
4. Di app: ikuti "Aktifkan dalam 3 langkah". Android 13+: Info Aplikasi → ⋮ → Izinkan setelan terbatas.
5. Rilis: `flutter build apk --release`.

## Jika berhenti bekerja
YouTube mengubah ID/teks tombol antar versi. Edit `skipIds`, `adIds`, `strongSkipTexts`
di `android/app/src/main/kotlin/com/example/ytskips/SkipService.kt`.
